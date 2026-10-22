defmodule WardrikPolicy.JudgeTest do
  use ExUnit.Case, async: true

  alias WardrikPolicy.Decision

  doctest WardrikPolicy.Judge

  @books "Does this call change the books?"
  @money "Does this call send money outside the company?"

  setup do
    judge = [
      questions: [
        [question: @books, tools: ["books/*"], ask: 0.5, allow: 0.05],
        [question: @money, ask: 0.5, deny: 0.9, message: "Money stays in."]
      ]
    ]

    %{judge: judge}
  end

  test "decides by the strictest answer", %{judge: judge} do
    policy = WardrikPolicy.new!(judge: judge)

    assert {:deny, "Money stays in."} = decide(policy, "books__pay", [0.1, 0.95])
    assert {:ask, "Judged 60% likely: " <> @books} = decide(policy, "books__pay", [0.6, 0.1])
    assert {:ask, "Money stays in."} = decide(policy, "books__pay", [0.2, 0.7])
  end

  test "allows by name only when every allow holds", %{judge: judge} do
    policy = WardrikPolicy.new!(default: :ask, judge: judge)

    assert %Decision{effect: :allow, cause: :judge} =
             explain(policy, "books__list", [0.01, 0.2], gated: true)

    assert %Decision{effect: :ask, cause: :no_rule} = explain(policy, "books__list", [0.2, 0.2])
  end

  test "asks only the questions that name the call", %{judge: judge} do
    policy = WardrikPolicy.new!(judge: judge)
    test = self()

    evaluate = fn "typesafe:jev-latest", state, questions ->
      send(test, {:asked, state, questions})
      {:ok, [0.1]}
    end

    assert :allow = WardrikPolicy.decide(policy, "web_search", evaluate: evaluate)
    assert_received {:asked, %{"tool" => "web_search", "arguments" => %{}}, [@money]}
  end

  test "never lifts a rule's ask or deny", %{judge: judge} do
    policy = WardrikPolicy.new!(ask: ["books/*"], deny: ["shell/*"], judge: judge)

    assert {:ask, "books/list needs your approval."} = decide(policy, "books__list", [0.01, 0.0])

    assert {:deny, _message} =
             WardrikPolicy.decide(policy, "shell__exec", evaluate: fn _, _, _ -> flunk() end)
  end

  test "asks a person when it can't answer a question that could ask", %{judge: judge} do
    policy = WardrikPolicy.new!(judge: judge)

    assert {:ask, "The judge couldn't answer (:timeout), so a person decides."} =
             WardrikPolicy.decide(policy, "web_search",
               evaluate: fn _, _, _ -> {:error, :timeout} end
             )

    assert {:ask, "The judge couldn't answer (:no_evaluate)" <> _rest} =
             WardrikPolicy.decide(policy, "web_search")
  end

  test "says nothing when it can't answer a question that only allows" do
    policy = WardrikPolicy.new!(judge: [questions: [[question: @books, allow: 0.05]]])

    assert :allow = WardrikPolicy.decide(policy, "web_search")
  end

  defp decide(policy, name, probabilities),
    do: WardrikPolicy.decide(policy, name, evaluate: answers(probabilities))

  defp explain(policy, name, probabilities, opts \\ []),
    do: WardrikPolicy.explain(policy, name, [evaluate: answers(probabilities)] ++ opts)

  defp answers(probabilities) do
    fn _model, _state, questions -> {:ok, Enum.take(probabilities, length(questions))} end
  end
end
