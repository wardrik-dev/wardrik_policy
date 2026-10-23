defmodule WardrikPolicy.AgentTest do
  use ExUnit.Case, async: false
  use Mimic

  alias WardrikPolicy.Ask

  defmodule Books do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, test) do
      [
        WardrikCore.Tool.new!(
          name: "books__create_bill",
          description: "Create a bill.",
          schema: [amount: [type: :integer, required: true]],
          run: fn %{amount: amount}, _context ->
            send(test, {:billed, amount})
            {:ok, "bill created"}
          end
        )
      ]
    end
  end

  setup :set_mimic_global

  setup do
    handler = "policy-agent-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:wardrik_core, :turn, :stop], &__MODULE__.stopped/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok
  end

  def stopped(_event, _measurements, metadata, test), do: send(test, {:stopped, metadata})

  test "a call the policy asks about waits for a person, then runs" do
    bill = ReqLLM.ToolCall.new("call_1", "books__create_bill", JSON.encode!(%{amount: 9400}))

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, response(tool_calls: [bill])} end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert %{role: :tool, tool_call_id: "call_1"} = List.last(messages)
      {:ok, response("Done.")}
    end)

    policy = WardrikPolicy.new!(ask: %{"books/create_bill(amount >= 1000)" => "Over $1,000."})
    id = "books-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      WardrikCore.start_agent(
        agent_id: id,
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{Books, self()}],
        middleware: [{WardrikPolicy.Middleware, policy}]
      )

    :ok = WardrikCore.ask(agent, "Pay the $9,400 invoice.")
    assert_receive {:stopped, %{agent_id: ^id, outcome: :park}}
    refute_received {:billed, _amount}

    assert {:tool_calls, [{%{id: "call_1"}, {:park, %Ask{message: "Over $1,000."}}}]} =
             WardrikCore.parked(agent)

    :ok = WardrikCore.resume(agent, %{"call_1" => :approve})
    assert_receive {:stopped, %{agent_id: ^id, outcome: :ok}}
    assert_received {:billed, 9400}
  end

  test "a model call past the budget waits for a person, across turns" do
    used = %{input_tokens: 600, output_tokens: 600, total_cost: 0.01}

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, %{response("Hi.") | usage: used}} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, response("Done.")} end)

    policy = WardrikPolicy.new!(budget: [tokens: 1000])
    id = "budget-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      WardrikCore.start_agent(
        agent_id: id,
        model: "anthropic:claude-haiku-4-5",
        middleware: [{WardrikPolicy.Middleware, policy}]
      )

    :ok = WardrikCore.ask(agent, "Hello.")
    assert_receive {:stopped, %{agent_id: ^id, outcome: :ok}}

    :ok = WardrikCore.ask(agent, "Pay the invoice.")
    assert_receive {:stopped, %{agent_id: ^id, outcome: :park}}

    assert %Ask{message: "This agent has used 1,200 of 1,000 tokens today." <> _rest} =
             WardrikCore.parked(agent)

    :ok = WardrikCore.resume(agent, %{"model" => :approve})
    assert_receive {:stopped, %{agent_id: ^id, outcome: :ok}}
  end

  defp response(text) when is_binary(text), do: response(ReqLLM.Context.assistant(text))
  defp response(tool_calls: calls), do: response(ReqLLM.Context.assistant("", tool_calls: calls))

  defp response(%ReqLLM.Message{} = message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
