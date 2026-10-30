if Code.ensure_loaded?(WardrikCore.Middleware) do
  defmodule WardrikPolicy.Middleware do
    @moduledoc """
    A `WardrikCore.Middleware` that holds an agent to one or more policies.

        middleware: [{WardrikPolicy.Middleware, WardrikPolicy.new!(deny: ["shell/*"])}]

    Pass a list to hold an agent to several policies, such as its org's and its own:

        middleware: [{WardrikPolicy.Middleware, [org_policy, agent_policy]}]

    For each tool call, it decides by the rules and judge before the call runs. A judge asks its
    model with `WardrikCore.evaluate/4`. A refused call returns the refusal as its error, so the
    model can carry on.

    For each model call, it checks the budgets before the call and counts the cost after.
    What was spent is kept in the context's private data, so it survives restarts.

    ## Answering an ask

    A call that asks parks on a `WardrikPolicy.Ask`. Answer it with `WardrikCore.resume/2`, keyed
    by the tool call's id, or `"model"` for a model call:

        WardrikCore.resume(agent, %{"call_123" => :approve})
        WardrikCore.resume(agent, %{"call_123" => {:approve, "Checked with finance."}})
        WardrikCore.resume(agent, %{"model" => {:deny, "Over budget for today."}})

    A note reaches the model beside the call's result. A reason reaches it as the call's error.
    Pass `%{by: who}` as `WardrikCore.resume/3`'s metadata to record who answered.

    A call parked `:in_doubt`, because it may already have run, takes the answer given for that.
    The person isn't asked twice.

    ## Events

    Each decision is set on the step's span as the `"wardrik.policy.decision"` attribute. See
    `WardrikCore.Context.attribute/3`.

    These events go through `WardrikCore.Event`, so they reach the agent's events sink and
    `:telemetry`:

      * `[:wardrik_policy, :decision]` - every decision.
      * `[:wardrik_policy, :answer]` - every answer. Carries the `metadata` given to
        `WardrikCore.resume/3`.
      * `[:wardrik, :tool_call, :denied]` - a tool call refused by a policy or a person.
      * `[:wardrik, :interrupt, :resolved]` - an ask answered.

    The first two carry `agent_id`, the step's `span`, the `call` (`nil` for a model call) and the
    run's `labels`. See `WardrikCore.Context.labels/1`.
    """
    @behaviour WardrikCore.Middleware

    alias WardrikCore.Context
    alias WardrikCore.Resume
    alias WardrikCore.Tool
    alias WardrikPolicy.Ask
    alias WardrikPolicy.Decision
    alias WardrikPolicy.Spending

    @impl WardrikCore.Middleware
    def call(%Context{step: {:tool_call, call}} = context, next, policies) do
      decision = WardrikPolicy.explain(policies, call.name, decide_opts(context, call))
      emit(:decision, context, call, %{decision: decision})
      context = context |> decided(decision) |> Context.measure(decision.measurements)
      follow(decision, context, call, next, next)
    end

    def call(%Context{step: :generate} = context, next, policies) do
      policies = List.wrap(policies)
      context = context |> Spending.start(policies) |> Spending.catch_up(policies)
      metered = &metered(&1, next, policies)

      case Spending.explain(context, policies) do
        %Decision{effect: :allow} ->
          metered.(context)

        decision ->
          emit(:decision, context, nil, %{decision: decision})
          approved = &metered.(Spending.grant(&1, policies))
          follow(decision, decided(context, decision), nil, metered, approved)
      end
    end

    def call(context, next, _policies), do: next.(context)

    defp metered(context, next, policies) do
      with {:ok, context} <- next.(context), do: {:ok, Spending.record(context, policies)}
    end

    defp follow(%Decision{effect: :allow}, context, _call, run, _approved), do: run.(context)

    defp follow(%Decision{effect: :deny, message: message}, context, call, _run, _approved) do
      denied(context, call, message, "hook")
      refused(context, call, message)
    end

    defp follow(%Decision{effect: :ask, message: message}, context, call, _run, approved) do
      case answer(context, call) do
        nil ->
          ask = %Ask{
            interrupt: interrupt(call),
            message: message,
            labels: Context.labels(context)
          }

          {:park, ask, context}

        answer ->
          emit(:answer, context, call, %{answer: answer, metadata: context.resume.metadata})
          resolved(context, call, answer)
          answered(answer, context, call, approved)
      end
    end

    defp interrupt(nil), do: "model_approval"
    defp interrupt(_call), do: "tool_approval"

    defp decide_opts(context, call) do
      annotations = annotations(Context.tool(context, call))

      [
        arguments: call.arguments,
        resources: resources(annotations[:resources], call.arguments),
        annotations: annotations,
        labels: Context.labels(context),
        evaluate: &evaluate(context, &1, &2, &3)
      ]
    end

    defp annotations(nil), do: %{}
    defp annotations(%Tool{annotations: annotations}), do: annotations

    defp resources(nil, _arguments), do: []
    defp resources(resources, arguments), do: resources.(arguments)

    defp evaluate(context, model, state, questions) do
      named =
        questions
        |> Enum.with_index()
        |> Map.new(fn {question, n} -> {"q#{n}", %{type: :boolean, instructions: question}} end)

      with {:ok, answers, measurements} <- WardrikCore.evaluate(context, model, state, named),
           {:ok, probabilities} <- probabilities(answers, length(questions)) do
        {:ok, probabilities, measurements}
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

    defp answer(%Context{resume: %Resume{reason: :in_doubt, input: input}}, %{id: id})
         when is_map(input),
         do: Map.get(input, id)

    defp answer(_context, _call), do: nil

    defp answer_id(nil), do: "model"
    defp answer_id(call), do: call.id

    defp answered(:approve, context, _call, next), do: next.(context)

    defp answered({:approve, note}, context, _call, next),
      do: with({:ok, context} <- next.(context), do: {:ok, noted(context, note)})

    defp answered({:deny, reason}, context, call, _next) do
      denied(context, call, reason, "person")
      refused(context, call, reason)
    end

    defp refused(_context, nil, message), do: {:error, message}
    defp refused(context, _call, message), do: {:ok, %{context | response: {:error, message}}}

    defp decided(context, decision),
      do: Context.attribute(context, "wardrik.policy.decision", decision)

    defp emit(event, context, call, metadata) do
      WardrikCore.Event.emit(
        context,
        [:wardrik_policy, event],
        %{},
        Map.merge(
          %{
            agent_id: context.agent_id,
            span: context.span,
            call: call,
            labels: Context.labels(context)
          },
          metadata
        )
      )
    end

    defp denied(_context, nil, _reason, _by), do: :ok

    defp denied(context, call, reason, by) do
      WardrikCore.Event.emit(context, [:wardrik, :tool_call, :denied], %{}, %{
        agent_id: context.agent_id,
        span: context.span,
        tool: %{name: call.name, call: %{id: call.id}},
        reason: reason,
        decided: %{by: by}
      })
    end

    defp resolved(context, call, answer) do
      WardrikCore.Event.emit(
        context,
        [:wardrik, :interrupt, :resolved],
        %{},
        Map.merge(
          %{agent_id: context.agent_id, span: context.span, interrupt: %{id: answer_id(call)}},
          resolution(answer, context.resume.metadata)
        )
      )
    end

    defp resolution(answer, metadata) do
      answer
      |> decision()
      |> put_present(:resolved_by, Map.get(metadata || %{}, :by))
    end

    defp decision(:approve), do: %{decision: "approved"}
    defp decision({:approve, note}), do: %{decision: "approved", note: note}
    defp decision({:deny, reason}), do: %{decision: "rejected", reason: reason}

    defp put_present(map, _key, nil), do: map
    defp put_present(map, key, value), do: Map.put(map, key, value)

    defp noted(%Context{response: {:ok, result}} = context, note),
      do: %{context | response: {:ok, %{"result" => result, "note" => note}}}

    defp noted(context, _note), do: context
  end
end
