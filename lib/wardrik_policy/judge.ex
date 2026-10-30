defmodule WardrikPolicy.Judge do
  @moduledoc """
  Asks a model yes-or-no questions about each tool call, and decides by the probability of yes.

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

  ## Options

    * `:model` - the model that answers. `"typesafe:jev-latest"` unless set.
    * `:questions` - a list of questions, each with the keys below.

  Each question takes:

    * `:question` - required. What the model is asked about the call.
    * `:tools` - tool names it applies to, as `["books/*"]`, without arguments. Every tool unless set.
    * `:deny` - refuse the call at or above this probability.
    * `:ask` - ask a person at or above this probability.
    * `:allow` - allow the call below this probability.
    * `:message` - the prompt or refusal to show in place of the question.

  Each threshold is a probability from 0 to 1. A question needs at least one of them.
  `decode/1` returns an error otherwise.

  ## Evaluating

  A call's questions go to the model in one request, with the tool's name and arguments. Pass a
  function as the `:evaluate` option of `WardrikPolicy.decide/3` to make that request. See
  `t:evaluate/0`. `WardrikPolicy.Middleware` uses `WardrikCore.evaluate/4`. What the request used
  is returned in the decision's `measurements`.

  ## How it combines with rules

    * A deny beats an ask, and an ask beats an allow, across questions and rules.
    * A judge's allow only decides calls no rule names. It never overrides a rule's ask or deny.
    * A judge's allow is ignored once the run has read content from outside.
    * If the model can't answer, the call asks a person, as long as some question could ask or deny.

  The call's arguments may be written to fool the judge. Keep exact checks in rules, and test the
  thresholds on real calls before trusting the judge's allow.
  """

  alias WardrikPolicy.Call
  alias WardrikPolicy.Decision
  alias WardrikPolicy.Name

  alias WardrikPolicy.Read

  @outside "outside"

  defstruct model: "typesafe:jev-latest", questions: []

  @fields ~w(model questions)
  @question %{
    "question" => :question,
    "tools" => :tools,
    "deny" => :deny,
    "ask" => :ask,
    "allow" => :allow,
    "message" => :message
  }

  @type question() :: %{
          required(:question) => String.t(),
          optional(:tools) => [String.t()],
          optional(:deny) => float(),
          optional(:ask) => float(),
          optional(:allow) => float(),
          optional(:message) => String.t()
        }
  @type t() :: %__MODULE__{model: String.t(), questions: [question() | keyword()]}

  @typedoc """
  Asks `model` each question about `state`. Returns each question's probability of yes, in order,
  and what the request used.
  """
  @type evaluate() ::
          (model :: String.t(), state :: map(), questions :: [String.t()] ->
             {:ok, [float()], measurements :: map()} | {:error, term()})

  @doc "Reads a judge from a map with string keys, such as one parsed from YAML."
  @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
  def decode(fields) when is_map(fields) do
    with :ok <- Read.known(fields, @fields, "a judge"),
         {:ok, questions} <- questions(Map.get(fields, "questions", [])) do
      {:ok,
       %__MODULE__{model: Map.get(fields, "model", %__MODULE__{}.model), questions: questions}}
    end
  end

  def decode(_fields), do: {:error, "a judge is a map of model and questions"}

  @doc "Encodes a judge as the map `decode/1` reads."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{model: model, questions: questions}),
    do: %{"model" => model, "questions" => Enum.map(questions, &Read.written/1)}

  defp questions(questions) when is_list(questions) do
    questions
    |> Enum.map(&question/1)
    |> Read.all()
  end

  defp questions(_questions), do: {:error, "a judge's questions are a list"}

  defp question(%{"question" => _question} = fields) do
    with {:ok, question} <- Read.keywords(fields, @question, "a question"),
         question = Map.new(question),
         :ok <- thresholds(question),
         :ok <- tools(question),
         do: decides(question)
  end

  defp question(_fields), do: {:error, "each of a judge's questions has a question"}

  defp thresholds(question) do
    case Enum.find([:deny, :ask, :allow], &(not probability?(Map.get(question, &1, 0)))) do
      nil -> :ok
      key -> {:error, "a question's #{key} is a probability between 0 and 1"}
    end
  end

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp tools(%{tools: tools}) when is_list(tools) do
    if Enum.all?(tools, &(is_binary(&1) and not String.contains?(&1, "("))),
      do: :ok,
      else: {:error, "a question's tools name tools alone, as books/*, without their arguments"}
  end

  defp tools(%{tools: _tools}), do: {:error, "a question's tools are a list of tool names"}
  defp tools(_question), do: :ok

  defp decides(question) do
    if Enum.any?([:deny, :ask, :allow], &Map.has_key?(question, &1)),
      do: {:ok, question},
      else: {:error, "a question decides nothing; give it deny, ask or allow"}
  end

  @doc """
  Decides a call to the tool `name` by the judge alone.

  Returns `:allow`, `{:ask, prompt}` or `{:deny, message}`. Returns `:pass` when no question applies
  or none crosses its threshold.
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
    case judge |> judge(call) |> trusted(call) do
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

  defp trusted({:allow, measurements}, %Call{labels: labels}) do
    if @outside in labels, do: {:pass, measurements}, else: {:allow, measurements}
  end

  defp trusted(judged, _call), do: judged

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
