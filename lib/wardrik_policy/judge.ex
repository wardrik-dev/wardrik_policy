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
      iex> evaluate = fn _model, _state, _questions -> {:ok, [0.72], %{}} end
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
  `evaluate:` option of `WardrikPolicy.decide/3` makes that call, and gives back what it used. The
  decision carries that as its `measurements`. `WardrikPolicy.Middleware` makes
  it with `WardrikCore.evaluate/4`.

  A deny beats an ask, and an ask beats an allow, across the questions and the rules. A judge's
  allow never lifts a call a rule asks about or denies. A judge that can't answer asks a person if
  any of its questions could ask or deny.

  Its allow trusts the call's arguments, and they may be written to fool it. Reach for it as a
  second opinion beside the rules, and try its thresholds on real calls before trusting them.
  """

  alias WardrikPolicy.Call
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
             {:ok, [float()], measurements :: map()} | {:error, term()})

  @doc """
  Decides a call to the tool `name`. Returns `:allow`, `{:ask, prompt}`, `{:deny, message}`, or
  `:pass` when it has nothing to say.
  """
  @spec decide(t(), String.t(), map(), evaluate() | nil) :: WardrikPolicy.decision() | :pass
  def decide(%__MODULE__{} = judge, name, arguments, evaluate) do
    {answer, _measurements} =
      judge(judge, Call.new(name, arguments: arguments, evaluate: evaluate))

    answer
  end

  @doc false
  @spec weigh(Decision.t(), t() | nil, Call.t()) :: Decision.t()
  def weigh(%Decision{effect: :deny} = decision, _judge, _call), do: decision
  def weigh(decision, nil, _call), do: decision

  def weigh(decision, judge, call) do
    case judge(judge, call) do
      {:pass, measurements} ->
        %{decision | measurements: measurements}

      {judged, measurements} ->
        %{over(decision, judged(decision.policy, judged)) | measurements: measurements}
    end
  end

  defp judge(judge, call) do
    case asked(judge, call) do
      [] -> {:pass, %{}}
      asked -> answered(asked, evaluation(judge, asked, call))
    end
  end

  defp judged(policy, :allow), do: %Decision{effect: :allow, policy: policy, cause: :judge}

  defp judged(policy, {effect, message}),
    do: %Decision{effect: effect, message: message, policy: policy, cause: :judge}

  defp over(%Decision{cause: :no_rule}, %Decision{effect: :allow} = judged), do: judged
  defp over(decision, %Decision{effect: :allow}), do: decision
  defp over(decision, judged), do: Decision.strictest([decision, judged])

  defp asked(judge, %Call{name: name}) do
    judge.questions
    |> Enum.map(&Map.new/1)
    |> Enum.filter(&names?(Map.get(&1, :tools, []), name))
  end

  defp names?([], _name), do: true
  defp names?(tools, name), do: Enum.any?(tools, &Name.match?(Name.glob(&1), name))

  defp evaluation(_judge, _asked, %Call{evaluate: nil}), do: {:error, :no_evaluate}

  defp evaluation(judge, asked, %Call{} = call) do
    state = %{"tool" => Name.shown(call.name), "arguments" => call.arguments}
    call.evaluate.(judge.model, state, Enum.map(asked, & &1.question))
  end

  defp answered(asked, {:ok, probabilities, measurements}),
    do: {verdict(Enum.zip(asked, probabilities)), measurements}

  defp answered(asked, {:error, reason}) do
    if Enum.any?(asked, &(Map.has_key?(&1, :deny) or Map.has_key?(&1, :ask))),
      do: {{:ask, "The judge couldn't answer (#{why(reason)}), so a person decides."}, %{}},
      else: {:pass, %{}}
  end

  defp why(%{__exception__: true} = error), do: Exception.message(error)
  defp why(reason), do: inspect(reason)

  defp verdict(answers) do
    with nil <- crossed(answers, :deny),
         nil <- crossed(answers, :ask) do
      if allowed?(answers), do: :allow, else: :pass
    end
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
