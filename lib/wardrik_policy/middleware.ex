if Code.ensure_loaded?(WardrikCore.Middleware) do
  defmodule WardrikPolicy.Middleware do
    @moduledoc """
    A `WardrikCore.Middleware` that runs a `WardrikPolicy` on every tool call an agent makes.

        middleware: [{WardrikPolicy.Middleware, WardrikPolicy.new!(deny: ["shell/*"])}]

    The policy decides before the tool runs. A call that asks parks on a `WardrikPolicy.Ask`.
    Answer it with `WardrikCore.resume/2`, giving each call id `:approve`, `{:approve, note}` or
    `{:deny, reason}`.

    Every decision emits `[:wardrik_policy, :decision]`, and every answer emits
    `[:wardrik_policy, :answer]`. Both carry the `agent_id` and the `call`.

    Reach for this when an agent's tools can spend money, send mail, or change anything you'd want
    a say in.
    """
    @behaviour WardrikCore.Middleware

    alias WardrikCore.Context
    alias WardrikCore.Tool
    alias WardrikPolicy.Ask
    alias WardrikPolicy.Decision

    @unannotated %{gated: false, subjects: nil}

    @impl WardrikCore.Middleware
    def call(%Context{step: {:tool_call, call}} = context, next, %WardrikPolicy{} = policy) do
      decision = WardrikPolicy.explain(policy, call.name, decide_opts(context, call))
      emit(:decision, context, call, %{decision: decision})

      case decision do
        %Decision{effect: :allow} -> next.(context)
        %Decision{effect: :deny, message: message} -> {:error, message}
        %Decision{effect: :ask, message: prompt} -> asked(context, next, call, prompt)
      end
    end

    def call(context, next, _policy), do: next.(context)

    defp decide_opts(context, call) do
      annotations = annotations(Context.tool(context, call))

      [
        arguments: call.arguments,
        subjects: subjects(annotations.subjects, call.arguments),
        gated: annotations.gated
      ]
    end

    defp annotations(nil), do: @unannotated
    defp annotations(tool), do: Tool.get_private(tool, WardrikPolicy, @unannotated)

    defp subjects(nil, _arguments), do: []
    defp subjects(subjects, arguments), do: subjects.(arguments)

    defp asked(%Context{resume: {%Ask{}, decisions}} = context, next, call, prompt)
         when is_map(decisions) do
      case Map.get(decisions, call.id) do
        nil ->
          {:park, %Ask{prompt: prompt}, context}

        answer ->
          emit(:answer, context, call, %{answer: answer})
          answered(answer, context, next)
      end
    end

    defp asked(context, _next, _call, prompt), do: {:park, %Ask{prompt: prompt}, context}

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
