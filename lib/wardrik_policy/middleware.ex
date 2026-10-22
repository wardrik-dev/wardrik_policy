if Code.ensure_loaded?(WardrikCore.Middleware) do
  defmodule WardrikPolicy.Middleware do
    @moduledoc """
    A `WardrikCore.Middleware` that decides each tool call with a `WardrikPolicy`.

        middleware: [{WardrikPolicy.Middleware, WardrikPolicy.new!(deny: ["shell/*"])}]

    Reads what `WardrikPolicy.annotate/2` marks a tool with. A call that asks parks on a
    `WardrikPolicy.Ask`, and `WardrikCore.resume/2` answers it with a map of call id to
    `:approve`, `{:approve, note}` or `{:deny, reason}`.
    """
    @behaviour WardrikCore.Middleware

    alias WardrikCore.Context
    alias WardrikCore.Tool
    alias WardrikPolicy.Ask

    @unannotated %{gated: false, subjects: nil}

    @impl WardrikCore.Middleware
    def call(%Context{step: {:tool_call, call}} = context, next, %WardrikPolicy{} = policy) do
      case WardrikPolicy.decide(policy, call.name, decide_opts(context, call)) do
        :allow -> next.(context)
        {:deny, message} -> {:error, message}
        {:ask, prompt} -> asked(context, next, call, prompt)
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
        :approve -> next.(context)
        {:approve, note} -> with {:ok, context} <- next.(context), do: {:ok, noted(context, note)}
        {:deny, reason} -> {:error, reason}
        nil -> {:park, %Ask{prompt: prompt}, context}
      end
    end

    defp asked(context, _next, _call, prompt), do: {:park, %Ask{prompt: prompt}, context}

    defp noted(%Context{response: {:ok, result}} = context, note),
      do: %{context | response: {:ok, %{"result" => result, "note" => note}}}

    defp noted(context, _note), do: context
  end
end
