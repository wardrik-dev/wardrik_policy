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

  describe "budgets" do
    setup do
      policy = WardrikPolicy.new!(budget: [usd: 1.00, tokens: 1000])
      %{context: Context.new(middleware: [{WardrikPolicy.Middleware, policy}])}
    end

    test "counts what each model call spent", %{context: context} do
      {:ok, context} = generate(context, usd: 0.40, tokens: 300)
      {:ok, context} = generate(context, usd: 0.25, tokens: 100)

      assert %{0 => %{usd: 0.65, tokens: 400, period: {:day, _today}}} =
               Context.get_private(context, WardrikPolicy.Budget)
    end

    test "the call that crosses a limit runs, and the next one asks", %{context: context} do
      {:ok, context} = generate(context, usd: 1.20)

      assert {:park, %Ask{prompt: "This agent has spent $1.20 of $1.00 today." <> _rest},
              _context} =
               generate(context)
    end

    test "an approval allows a grant's worth more", %{context: context} do
      {:ok, context} = generate(context, usd: 1.20)
      {:ok, context} = generate(answered(context, %{"model" => :approve}), usd: 0.50)
      {:ok, context} = generate(%{context | resume: nil}, usd: 0.60)

      assert {:park, %Ask{prompt: "This agent has spent $2.30 of $2.20 today." <> _rest},
              _context} =
               generate(context)
    end

    test "a denial ends the call with its reason", %{context: context} do
      {:ok, context} = generate(context, tokens: 1000)

      assert {:error, "Not today."} =
               generate(answered(context, %{"model" => {:deny, "Not today."}}))
    end

    test "on_exhausted: :deny refuses without asking" do
      policy = WardrikPolicy.new!(budget: [tokens: 10, on_exhausted: :deny])
      context = Context.new(middleware: [{WardrikPolicy.Middleware, policy}])
      {:ok, context} = generate(context, tokens: 20)

      assert {:error, "This agent has used 20 of 10 tokens today."} = generate(context)
    end

    test "a dollar budget refuses a model it can't price", %{context: context} do
      {:ok, context} = generate(context, usd: nil, tokens: 10)

      assert {:error, "This model has no price in dollars, so the budget can't hold it."} =
               generate(context)
    end

    test "a price stands in for a cost the model doesn't report" do
      policy = WardrikPolicy.new!(budget: [usd: 1.00, price: [input: 1.0, output: 1.0]])
      context = Context.new(middleware: [{WardrikPolicy.Middleware, policy}])
      {:ok, context} = generate(context, usd: nil, tokens: 500_000)

      assert %{0 => %{usd: 0.5}} = Context.get_private(context, WardrikPolicy.Budget)
    end

    test "a new period starts the count over", %{context: context} do
      context = Context.put_private(context, WardrikPolicy.Budget, %{0 => %{period: :yesterday}})

      assert {:ok, context} = generate(context, usd: 0.10)
      assert %{0 => %{usd: 0.10}} = Context.get_private(context, WardrikPolicy.Budget)
    end

    test "each policy's budget counts apart" do
      org = WardrikPolicy.new!([budget: [usd: 100.00]], name: "acme")
      agent = WardrikPolicy.new!([budget: [usd: 1.00, on_exhausted: :deny]], name: "books")
      context = Context.new(middleware: [{WardrikPolicy.Middleware, [org, agent]}])
      {:ok, context} = generate(context, usd: 2.00)

      assert {:error, "This agent has spent $2.00 of $1.00 today."} = generate(context)
      assert %{"acme" => %{usd: 2.0}} = Context.get_private(context, WardrikPolicy.Budget)
    end
  end

  defp generate(context, spent \\ []) do
    usage = %WardrikCore.Usage{
      input_tokens: Keyword.get(spent, :tokens, 0),
      usd: Keyword.get(spent, :usd, 0.0)
    }

    Context.run(context, :generate, &{:ok, %{&1 | usage: usage}})
  end

  defp answered(context, decisions),
    do: %{context | resume: %WardrikCore.Resume{reason: %Ask{prompt: "asked"}, input: decisions}}

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
