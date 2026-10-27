defmodule WardrikPolicy.MiddlewareTest do
  use ExUnit.Case, async: true
  use Mimic

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
      tool("write_file", resources: fn args -> [args["path"]] end),
      tool("refund_order"),
      tool("open_issue"),
      tool("list_issues", read_only: true),
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
    assert {:ok, %Context{response: {:error, "No shell."}}} = run(context, "shell__exec")
  end

  test "a call that asks parks on the question", %{context: context} do
    assert {:park, %Ask{message: "books/create_bill needs your approval."}, _context} =
             run(context, "books__create_bill")
  end

  test "the default turns on the tool's annotations", %{context: context} do
    policy = WardrikPolicy.new!(allow: ["refund_order"], default: [read_only: :allow, else: :ask])
    context = %{context | middleware: [{WardrikPolicy.Middleware, policy}]}

    assert {:ok, _context} = run(context, "list_issues")
    assert {:ok, _context} = run(context, "refund_order")

    assert {:park, %Ask{message: "open_issue needs your approval."}, _context} =
             run(context, "open_issue")
  end

  test "an allow covers a call only where it names what the call acts on", %{context: context} do
    assert {:ok, _context} = run(context, "write_file", %{path: "secrets/key"})

    strict =
      put_in(context.middleware, [{WardrikPolicy.Middleware, WardrikPolicy.new!(default: :deny)}])

    assert {:ok, %Context{response: {:error, _message}}} =
             run(strict, "write_file", %{path: "secrets/key"})
  end

  test "takes several policies, and the strictest decision wins", %{context: context} do
    org = WardrikPolicy.new!(deny: %{"books/*" => "Not in this org."})
    agent = WardrikPolicy.new!(ask: ["books/*"])
    context = %{context | middleware: [{WardrikPolicy.Middleware, [agent, org]}]}

    assert {:ok, %Context{response: {:error, "Not in this org."}}} =
             run(context, "books__create_bill")
  end

  describe "labels" do
    setup %{context: context} do
      messages = [ReqLLM.Context.user("Look at this page.", %{labels: ["outside"]})]
      tools = [tool("refund_order", gated: true) | context.tools]
      %{context: %{context | messages: messages, tools: tools}}
    end

    test "a gated call waits once the run has read content from outside, with its labels",
         %{context: context} do
      assert {:park, %Ask{labels: ["outside"], message: message}, _context} =
               run(context, "refund_order")

      assert message =~ "refund_order is allowed, but this run has read content from outside"
      assert {:ok, _context} = run(context, "write_file", %{path: "notes/a"})
    end
  end

  describe "events" do
    setup %{context: context} do
      agent_id = "events-#{System.unique_integer([:positive])}"
      test = self()

      events = [
        [:wardrik_policy, :decision],
        [:wardrik_policy, :answer],
        [:wardrik, :tool_call, :denied],
        [:wardrik, :interrupt, :resolved]
      ]

      :telemetry.attach_many(
        agent_id,
        events,
        fn name, _measurements, metadata, _config ->
          if metadata.agent_id == agent_id, do: send(test, {List.last(name), metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(agent_id) end)
      %{context: %{context | agent_id: agent_id}}
    end

    test "each decision is an event, with the rule that made it", %{context: context} do
      run(
        %{context | messages: [ReqLLM.Context.user("Hi.", %{labels: ["outside"]})]},
        "shell__exec"
      )

      assert_receive {:decision,
                      %{
                        call: %{name: "shell__exec"},
                        labels: ["outside"],
                        decision: %WardrikPolicy.Decision{effect: :deny, rule: "shell/*"}
                      }}
    end

    test "a call the rules refuse is the protocol's tool_call.denied", %{context: context} do
      run(context, "shell__exec")

      assert_receive {:denied,
                      %{
                        tool: %{name: "shell__exec", call: %{id: "1"}},
                        reason: "No shell.",
                        decided: %{by: "hook"}
                      }}
    end

    test "an answer is the protocol's interrupt.resolved", %{context: context} do
      maria = %WardrikCore.Principal{id: "user:maria"}
      resume(context, "books__create_bill", %{"1" => {:approve, "Pay it Friday."}}, %{by: maria})

      assert_receive {:resolved,
                      %{
                        interrupt: %{id: "1"},
                        decision: "approved",
                        note: "Pay it Friday.",
                        resolved_by: ^maria
                      }}

      resume(context, "books__create_bill", %{"1" => {:deny, "Not this month."}})

      assert_receive {:resolved, %{decision: "rejected", reason: "Not this month."} = resolved}
      refute Map.has_key?(resolved, :resolved_by)
      assert_receive {:denied, %{reason: "Not this month.", decided: %{by: "person"}}}
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
      assert {:ok, %Context{response: {:error, "Not this month."}}} =
               resume(context, "books__create_bill", %{"1" => {:deny, "Not this month."}})
    end

    test "a call left undecided keeps waiting", %{context: context} do
      assert {:park, %Ask{}, _context} = resume(context, "books__create_bill", %{"2" => :approve})
    end

    test "a call a person approved running again, as it may have run, runs without asking again",
         %{context: context} do
      resume = %WardrikCore.Resume{reason: :in_doubt, input: %{"1" => :approve}}

      assert {:ok, %Context{response: {:ok, "ran"}}} =
               run(%{context | resume: resume}, "books__create_bill")

      resume = %WardrikCore.Resume{reason: :in_doubt, input: %{"1" => {:deny, "Not again."}}}

      assert {:ok, %Context{response: {:error, "Not again."}}} =
               run(%{context | resume: resume}, "books__create_bill")
    end

    test "a call the policy now refuses is refused, approved or not", %{context: context} do
      context =
        put_in(context.middleware, [{WardrikPolicy.Middleware, WardrikPolicy.new!(deny: ["*"])}])

      assert {:ok, %Context{response: {:error, _message}}} =
               resume(context, "books__create_bill", %{"1" => :approve})
    end
  end

  describe "judges" do
    setup %{context: context} do
      policy =
        WardrikPolicy.new!(
          judge: [
            model: "typesafe:jev-latest",
            questions: [
              [question: "Does it change the books?", tools: ["books/*"], ask: 0.5],
              [question: "Does it send money out?", deny: 0.9]
            ]
          ]
        )

      %{context: put_in(context.middleware, [{WardrikPolicy.Middleware, policy}])}
    end

    test "asks the model about each call, with WardrikCore.evaluate/4", %{context: context} do
      expect(WardrikCore, :evaluate, fn _context, "typesafe:jev-latest", state, questions ->
        assert %{"tool" => "books/create_bill", "arguments" => %{"amount" => 9400}} = state

        assert %{
                 "q0" => %{type: :boolean, instructions: "Does it change the books?"},
                 "q1" => %{type: :boolean, instructions: "Does it send money out?"}
               } = questions

        {:ok, %{"q0" => %{"probability" => 0.8}, "q1" => %{"probability" => 0.1}}, %{usd: 0.0002}}
      end)

      assert {:park, %Ask{message: "Judged 80% likely: Does it change the books?"},
              %Context{measurements: %{usd: 0.0002}}} =
               run(context, "books__create_bill", %{amount: 9400})
    end

    test "a judge with no usable answer asks a person", %{context: context} do
      expect(WardrikCore, :evaluate, fn _context, _model, _state, _questions ->
        {:ok, %{}, %{}}
      end)

      assert {:park, %Ask{message: "The judge couldn't answer (:no_answer)" <> _rest}, _context} =
               run(context, "web_search")
    end
  end

  describe "budgets" do
    setup do
      policy = WardrikPolicy.new!(budget: [usd: 1.00, tokens: 1000])
      %{context: metered(policy)}
    end

    test "counts what each model call spent", %{context: context} do
      {:ok, context} = generate(context, usd: 0.40, tokens: 300)
      {:ok, context} = generate(context, usd: 0.25, tokens: 100)

      assert %{0 => %{usd: 0.65, tokens: 400, period: {:day, _today}}} =
               Context.get_private(context, WardrikPolicy.Budget)
    end

    test "the call that crosses a limit runs, and the next one asks", %{context: context} do
      {:ok, context} = generate(context, usd: 1.20)

      assert {:park, %Ask{message: "This agent has spent $1.20 of $1.00 today." <> _rest},
              _context} =
               generate(context)
    end

    test "an approval allows a grant's worth more", %{context: context} do
      {:ok, context} = generate(context, usd: 1.20)
      {:ok, context} = generate(answered(context, %{"model" => :approve}), usd: 0.50)
      {:ok, context} = generate(%{context | resume: nil}, usd: 0.60)

      assert {:park, %Ask{message: "This agent has spent $2.30 of $2.20 today." <> _rest},
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
      context = metered(policy)
      {:ok, context} = generate(context, tokens: 20)

      assert {:error, "This agent has used 20 of 10 tokens today."} = generate(context)
    end

    test "a dollar budget refuses a model it can't price", %{context: context} do
      {:ok, context} = generate(context, usd: nil, tokens: 10)

      assert {:error, "This model has no price in dollars, so the budget can't hold it."} =
               generate(context)
    end

    test "an unpriced tool call between model calls doesn't stop a dollar budget",
         %{context: context} do
      {:ok, context} = generate(context, usd: 0.10)
      context = Context.measure(context, %{input_tokens: 300, unpriced_calls: 1})

      assert {:ok, context} = generate(context, usd: 0.10)

      assert %{0 => %{usd: 0.2, unpriced: false}} =
               Context.get_private(context, WardrikPolicy.Budget)
    end

    test "a price stands in for a cost the model doesn't report" do
      policy = WardrikPolicy.new!(budget: [usd: 1.00, price: [input: 1.0, output: 1.0]])
      context = metered(policy)
      {:ok, context} = generate(context, usd: nil, tokens: 500_000)

      assert %{0 => %{usd: 0.5}} = Context.get_private(context, WardrikPolicy.Budget)
    end

    test "a price given once a call went unpriced lets the next one run", %{context: context} do
      {:ok, context} = generate(context, usd: nil, tokens: 10)

      priced =
        WardrikPolicy.new!(budget: [usd: 1.00, tokens: 1000, price: [input: 1.0, output: 1.0]])

      assert {:ok, _context} =
               generate(%{context | middleware: [{WardrikPolicy.Middleware, priced}]})
    end

    test "a new period starts the count over", %{context: context} do
      context = Context.put_private(context, WardrikPolicy.Budget, %{0 => %{period: :yesterday}})

      assert {:ok, context} = generate(context, usd: 0.10)
      assert %{0 => %{usd: 0.10}} = Context.get_private(context, WardrikPolicy.Budget)
    end

    test "each policy's budget counts apart" do
      org = WardrikPolicy.new!([budget: [usd: 100.00]], name: "acme")
      agent = WardrikPolicy.new!([budget: [usd: 1.00, on_exhausted: :deny]], name: "books")
      context = metered([org, agent])
      {:ok, context} = generate(context, usd: 2.00)

      assert {:error, "This agent has spent $2.00 of $1.00 today."} = generate(context)
      assert %{"acme" => %{usd: 2.0}} = Context.get_private(context, WardrikPolicy.Budget)
    end
  end

  defp generate(context, spent \\ []) do
    measured =
      priced(%{input_tokens: Keyword.get(spent, :tokens, 0)}, Keyword.get(spent, :usd, 0.0))

    Context.run(context, :generate, fn context ->
      {:ok,
       Enum.reduce(measured, context, fn {key, amount}, c -> Context.measure(c, key, amount) end)}
    end)
  end

  defp priced(measured, nil), do: Map.put(measured, :unpriced_calls, 1)
  defp priced(measured, usd), do: Map.put(measured, :usd, usd)

  defp metered(policies),
    do:
      Context.new(
        middleware: [{WardrikPolicy.Middleware, policies}],
        span: WardrikCore.Span.root()
      )

  defp answered(context, decisions),
    do: %{
      context
      | resume: %WardrikCore.Resume{
          reason: %Ask{interrupt: "tool_approval", message: "asked"},
          input: decisions
        }
    }

  defp run(context, name, args \\ %{}) do
    arguments = Map.new(args, fn {key, value} -> {to_string(key), value} end)
    call = %WardrikCore.ToolCall{id: "1", name: name, arguments: arguments}
    Context.run(context, {:tool_call, call}, &{:ok, %{&1 | response: {:ok, "ran"}}})
  end

  defp resume(context, name, decisions, metadata \\ %{}) do
    resume = %WardrikCore.Resume{
      reason: %Ask{interrupt: "tool_approval", message: "asked"},
      input: decisions,
      metadata: metadata
    }

    run(%{context | resume: resume}, name)
  end

  defp tool(name, annotations \\ []) do
    WardrikCore.Tool.new!(
      name: name,
      description: name,
      run: fn _args, _context -> {:ok, "ran"} end,
      annotations: annotations
    )
  end
end
