defmodule WardrikPolicy.MiddlewareTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Context
  alias WardrikPolicy.Ask

  setup do
    policy =
      WardrikPolicy.new!(
        allow: ["write_file(notes/*)", "refund_order"],
        ask: ["books/*"],
        deny: %{"shell/*" => "No shell."}
      )

    tools = [
      tool("write_file", subjects: fn args -> [args["path"]] end),
      tool("refund_order", gated: true),
      tool("open_issue", gated: true),
      tool("books__create_bill"),
      tool("shell__exec")
    ]

    %{context: Context.new(tools: tools, middleware: [{WardrikPolicy.Middleware, policy}])}
  end

  test "a call the rules allow runs", %{context: context} do
    assert {:ok, %Context{response: {:ok, "ran"}}} =
             run(context, "write_file", %{path: "notes/a"})

    assert {:ok, _context} = run(context, "refund_order")
  end

  test "a denied call is answered with the rule's message", %{context: context} do
    assert {:error, "No shell."} = run(context, "shell__exec")
  end

  test "a call that asks parks on the question", %{context: context} do
    assert {:park, %Ask{prompt: "books/create_bill needs your approval."}, _context} =
             run(context, "books__create_bill")
  end

  test "a gated tool asks unless a rule allows it by name", %{context: context} do
    assert {:park, %Ask{prompt: "open_issue can change something."}, _context} =
             run(context, "open_issue")
  end

  test "an allow covers a call only where it names what the call acts on", %{context: context} do
    assert {:ok, _context} = run(context, "write_file", %{path: "secrets/key"})

    strict =
      put_in(context.middleware, [{WardrikPolicy.Middleware, WardrikPolicy.new!(default: :deny)}])

    assert {:error, _message} = run(strict, "write_file", %{path: "secrets/key"})
  end

  test "takes several policies, and the strictest decision wins", %{context: context} do
    org = WardrikPolicy.new!(deny: %{"books/*" => "Not in this org."})
    agent = WardrikPolicy.new!(ask: ["books/*"])
    context = %{context | middleware: [{WardrikPolicy.Middleware, [agent, org]}]}

    assert {:error, "Not in this org."} = run(context, "books__create_bill")
  end

  test "annotate/2 rejects options it doesn't know" do
    assert_raise ArgumentError, ~r/unknown keys \[:gate\]/, fn ->
      tool("write_file", gate: true)
    end
  end

  describe "events" do
    setup %{context: context} do
      agent_id = "events-#{System.unique_integer([:positive])}"
      test = self()
      events = [[:wardrik_policy, :decision], [:wardrik_policy, :answer]]

      :telemetry.attach_many(
        agent_id,
        events,
        fn [:wardrik_policy, event], _measurements, metadata, _config ->
          if metadata.agent_id == agent_id, do: send(test, {event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(agent_id) end)
      %{context: %{context | agent_id: agent_id}}
    end

    test "each decision is an event, with the rule that made it", %{context: context} do
      run(context, "shell__exec")

      assert_receive {:decision,
                      %{
                        call: %{name: "shell__exec"},
                        decision: %WardrikPolicy.Decision{effect: :deny, rule: "shell/*"}
                      }}
    end

    test "a person's answer is an event", %{context: context} do
      resume(context, "books__create_bill", %{"1" => {:approve, "Pay it Friday."}}, %{by: "maria"})

      assert_receive {:decision, %{decision: %WardrikPolicy.Decision{effect: :ask}}}

      assert_receive {:answer,
                      %{
                        call: %{id: "1"},
                        answer: {:approve, "Pay it Friday."},
                        metadata: %{by: "maria"}
                      }}
    end

    test "a call left waiting has no answer", %{context: context} do
      resume(context, "books__create_bill", %{"2" => :approve})

      assert_receive {:decision, _metadata}
      refute_receive {:answer, _metadata}
    end
  end

  describe "resuming" do
    test "an approved call runs", %{context: context} do
      assert {:ok, %Context{response: {:ok, "ran"}}} =
               resume(context, "books__create_bill", %{"1" => :approve})
    end

    test "an approval's note goes to the model beside the result", %{context: context} do
      assert {:ok, %Context{response: {:ok, %{"result" => "ran", "note" => "Pay it Friday."}}}} =
               resume(context, "books__create_bill", %{"1" => {:approve, "Pay it Friday."}})
    end

    test "a denied call is answered with the reason", %{context: context} do
      assert {:error, "Not this month."} =
               resume(context, "books__create_bill", %{"1" => {:deny, "Not this month."}})
    end

    test "a call left undecided keeps waiting", %{context: context} do
      assert {:park, %Ask{}, _context} = resume(context, "books__create_bill", %{"2" => :approve})
    end

    test "a call the policy now refuses is refused, approved or not", %{context: context} do
      context =
        put_in(context.middleware, [{WardrikPolicy.Middleware, WardrikPolicy.new!(deny: ["*"])}])

      assert {:error, _message} = resume(context, "books__create_bill", %{"1" => :approve})
    end
  end

  defp run(context, name, args \\ %{}) do
    arguments = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    call = %WardrikCore.ToolCall{id: "1", name: name, arguments: arguments}
    Context.run(context, {:tool_call, call}, &{:ok, %{&1 | response: {:ok, "ran"}}})
  end

  defp resume(context, name, decisions, metadata \\ %{}) do
    resume = %WardrikCore.Resume{
      reason: %Ask{prompt: "asked"},
      input: decisions,
      metadata: metadata
    }

    run(%{context | resume: resume}, name)
  end

  defp tool(name, annotations \\ []) do
    WardrikCore.Tool.new!(
      name: name,
      description: name,
      run: fn _args, _context -> {:ok, "ran"} end
    )
    |> WardrikPolicy.annotate(annotations)
  end
end
