defmodule WardrikPolicy.Judge do
  @moduledoc """
  A judge asks a model yes-or-no questions about each tool call, and decides by the probability of
  yes.

      iex> policy =
      ...>   WardrikPolicy.new!(
      ...>     judge: [
      ...>       questions: [
      ...>         [
      ...>           question: "Does this call send money outside the company?",
      ...>           tools: ["books/*"],
      ...>           ask: 0.5,
      ...>           deny: 0.9
      ...>         ]
      ...>       ]
      ...>     ]
      ...>   )
      iex> evaluate = fn _model, _state, _questions -> {:ok, [0.72]} end
      iex> WardrikPolicy.decide(policy, "books__pay_bill", evaluate: evaluate)
      {:ask, "Judged 72% likely: Does this call send money outside the company?"}

  Each question takes:

    * `question` - what the model is asked about the call.
    * `tools` - the tools it's asked about, as `["books/*"]`. Every tool unless set.
    * `deny` - refuse the call at or above this probability.
    * `ask` - ask a person first at or above this probability.
    * `allow` - allow the call by name below this probability.
    * `message` - what the person is asked, or the model told, in place of the question.

  The questions a call is asked go to `model` together, with the tool's name and arguments. The
  `evaluate:` option of `WardrikPolicy.decide/3` makes that call. `WardrikPolicy.Middleware` makes
  it with `WardrikCore.evaluate/4`.

  A deny beats an ask, and an ask beats an allow, across the questions and the rules. A judge's
  allow never lifts a call a rule asks about or denies. A judge that can't answer asks a person if
  any of its questions could ask or deny.

  Its allow trusts the call's arguments, and they may be written to fool it. Reach for it as a
  second opinion beside the rules, and try its thresholds on real calls before trusting them.
  """

  alias WardrikPolicy.Decision
  alias WardrikPolicy.Name

  defstruct model: "typesafe:jev-latest", questions: []

  @type question() :: %{
          required(:question) => String.t(),
          optional(:tools) => [String.t()],
          optional(:deny) => float(),
          optional(:ask) => float(),
          optional(:allow) => float(),
          optional(:message) => String.t()
        }
  @type t() :: %__MODULE__{model: String.t(), questions: [question() | keyword()]}

  @typedoc "Asks `model` each question about `state`, and gives each one's probability of yes."
  @type evaluate() ::
          (model :: String.t(), state :: map(), questions :: [String.t()] ->
             {:ok, [float()]} | {:error, term()})

  @doc """
  Decides a call to the tool `name`. Returns `:allow`, `{:ask, prompt}`, `{:deny, message}`, or
  `:pass` when it has nothing to say.
  """
  @spec decide(t(), String.t(), map(), evaluate() | nil) :: WardrikPolicy.decision() | :pass
  def decide(%__MODULE__{} = judge, name, arguments, evaluate) do
    case asked(judge, name) do
      [] -> :pass
      asked -> answered(asked, evaluation(judge, asked, name, arguments, evaluate))
    end
  end

  @doc false
  @spec weigh(Decision.t(), t() | nil, String.t(), keyword()) :: Decision.t()
  def weigh(%Decision{effect: :deny} = decision, _judge, _name, _opts), do: decision
  def weigh(decision, nil, _name, _opts), do: decision

  def weigh(decision, judge, name, opts) do
    case decide(judge, name, opts[:arguments], opts[:evaluate]) do
      :pass -> decision
      judged -> over(decision, judged(decision.policy, judged))
    end
  end

  defp judged(policy, :allow), do: %Decision{effect: :allow, policy: policy, cause: :judge}

  defp judged(policy, {effect, message}),
    do: %Decision{effect: effect, message: message, policy: policy, cause: :judge}

  defp over(%Decision{cause: :no_rule}, %Decision{effect: :allow} = judged), do: judged
  defp over(decision, %Decision{effect: :allow}), do: decision
  defp over(decision, judged), do: Decision.strictest([decision, judged])

  defp asked(judge, name) do
    judge.questions
    |> Enum.map(&Map.new/1)
    |> Enum.filter(&names?(Map.get(&1, :tools, []), name))
  end

  defp names?([], _name), do: true
  defp names?(tools, name), do: Enum.any?(tools, &Name.match?(Name.glob(&1), name))

  defp evaluation(_judge, _asked, _name, _arguments, nil), do: {:error, :no_evaluate}

  defp evaluation(judge, asked, name, arguments, evaluate) do
    state = %{"tool" => Name.shown(name), "arguments" => arguments}
    evaluate.(judge.model, state, Enum.map(asked, & &1.question))
  end

  defp answered(asked, {:ok, probabilities}) do
    answers = Enum.zip(asked, probabilities)

    with nil <- crossed(answers, :deny),
         nil <- crossed(answers, :ask) do
      if allowed?(answers), do: :allow, else: :pass
    end
  end

  defp answered(asked, {:error, reason}) do
    if Enum.any?(asked, &(Map.has_key?(&1, :deny) or Map.has_key?(&1, :ask))),
      do: {:ask, "The judge couldn't answer (#{inspect(reason)}), so a person decides."},
      else: :pass
  end

  defp crossed(answers, effect) do
    case Enum.find(answers, &over?(&1, effect)) do
      nil -> nil
      answer -> {effect, said(answer)}
    end
  end

  defp over?({question, probability}, effect),
    do: Map.has_key?(question, effect) and probability >= Map.fetch!(question, effect)

  defp allowed?(answers) do
    case Enum.filter(answers, fn {question, _probability} -> Map.has_key?(question, :allow) end) do
      [] ->
        false

      allowing ->
        Enum.all?(allowing, fn {question, probability} -> probability < question.allow end)
    end
  end

  defp said({%{message: message}, _probability}), do: message

  defp said({question, probability}),
    do: "Judged #{round(probability * 100)}% likely: #{question.question}"
end
