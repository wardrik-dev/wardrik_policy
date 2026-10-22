if Code.ensure_loaded?(WardrikCore.Middleware) do
  defmodule WardrikPolicy.Middleware do
    @moduledoc """
    A `WardrikCore.Middleware` that runs a `WardrikPolicy` on every call an agent makes.

        middleware: [{WardrikPolicy.Middleware, WardrikPolicy.new!(deny: ["shell/*"])}]

    Give it a list to hold an agent to several policies at once, like an org's and its own.

    The rules, and a policy's judge, decide each tool call before it runs. A judge asks its model with
    `WardrikCore.evaluate/4`. A policy's budget checks each model call before
    it runs, and counts what it spent after. What was spent stays with the agent in its context's
    private data; see `WardrikCore.Context`.

    A call that asks parks on a `WardrikPolicy.Ask`. Answer it with `WardrikCore.resume/2`, giving
    each tool call's id, or `"model"` for a model call, `:approve`, `{:approve, note}` or
    `{:deny, reason}`.

    Every decision emits `[:wardrik_policy, :decision]`, and every answer emits
    `[:wardrik_policy, :answer]`. Both carry the `agent_id` and the `call`, which is `nil` for a
    model call. An answer carries the `metadata` given to `WardrikCore.resume/3`, like who answered.

    Reach for this when an agent's tools can spend money, send mail, or change anything you'd want
    a say in.
    """
    @behaviour WardrikCore.Middleware

    alias WardrikCore.Context
    alias WardrikCore.Resume
    alias WardrikCore.Tool
    alias WardrikPolicy.Ask
    alias WardrikPolicy.Decision
    alias WardrikPolicy.Spending

    @unannotated %{gated: false, subjects: nil}

    @impl WardrikCore.Middleware
    def call(%Context{step: {:tool_call, call}} = context, next, policies) do
      decision = WardrikPolicy.explain(policies, call.name, decide_opts(context, call))
      emit(:decision, context, call, %{decision: decision})
      follow(decision, context, call, next, next)
    end

    def call(%Context{step: :generate} = context, next, policies) do
      policies = List.wrap(policies)
      context = Spending.start(context, policies)
      metered = &metered(&1, next, policies)

      case Spending.explain(context, policies) do
        %Decision{effect: :allow} ->
          metered.(context)

        decision ->
          emit(:decision, context, nil, %{decision: decision})
          follow(decision, context, nil, metered, &metered.(Spending.grant(&1, policies)))
      end
    end

    def call(context, next, _policies), do: next.(context)

    defp metered(context, next, policies) do
      with {:ok, context} <- next.(context), do: {:ok, Spending.record(context, policies)}
    end

    defp follow(%Decision{effect: :allow}, context, _call, run, _approved), do: run.(context)

    defp follow(%Decision{effect: :deny, message: message}, _context, _call, _run, _approved),
      do: {:error, message}

    defp follow(%Decision{effect: :ask, message: prompt}, context, call, _run, approved) do
      case answer(context, call) do
        nil ->
          {:park, %Ask{prompt: prompt}, context}

        answer ->
          emit(:answer, context, call, %{answer: answer, metadata: context.resume.metadata})
          answered(answer, context, approved)
      end
    end

    defp decide_opts(context, call) do
      annotations = annotations(Context.tool(context, call))

      [
        arguments: call.arguments,
        subjects: subjects(annotations.subjects, call.arguments),
        gated: annotations.gated,
        evaluate: &evaluate(context, &1, &2, &3)
      ]
    end

    defp annotations(nil), do: @unannotated
    defp annotations(tool), do: Tool.get_private(tool, WardrikPolicy, @unannotated)

    defp subjects(nil, _arguments), do: []
    defp subjects(subjects, arguments), do: subjects.(arguments)

    defp evaluate(context, model, state, questions) do
      named =
        questions
        |> Enum.with_index()
        |> Map.new(fn {question, n} -> {"q#{n}", %{type: :boolean, instructions: question}} end)

      with {:ok, answers, _usage} <- WardrikCore.evaluate(context, model, state, named) do
        probabilities(answers, length(questions))
      end
    end

    defp probabilities(answers, count) do
      probabilities = for n <- 0..(count - 1), do: get_in(answers, ["q#{n}", "probability"])

      if Enum.all?(probabilities, &is_number/1),
        do: {:ok, probabilities},
        else: {:error, :no_answer}
    end

    defp answer(%Context{resume: %Resume{reason: %Ask{}, input: input}}, call) when is_map(input),
      do: Map.get(input, answer_id(call))

    defp answer(_context, _call), do: nil

    defp answer_id(nil), do: "model"
    defp answer_id(call), do: call.id

    defp answered(:approve, context, next), do: next.(context)

    defp answered({:approve, note}, context, next),
      do: with({:ok, context} <- next.(context), do: {:ok, noted(context, note)})

    defp answered({:deny, reason}, _context, _next), do: {:error, reason}

    defp emit(event, context, call, metadata) do
      :telemetry.execute(
        [:wardrik_policy, event],
        %{},
        Map.merge(%{agent_id: context.agent_id, call: call}, metadata)
      )
    end

    defp noted(%Context{response: {:ok, result}} = context, note),
      do: %{context | response: {:ok, %{"result" => result, "note" => note}}}

    defp noted(context, _note), do: context
  end
end
