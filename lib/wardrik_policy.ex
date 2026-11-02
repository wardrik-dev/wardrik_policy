defmodule WardrikPolicy do
  @moduledoc """
  Decides each tool call an agent makes: run it, ask a person first, or refuse it.

      iex> policy =
      ...>   WardrikPolicy.new!(
      ...>     allow: ["web_search", "write_file(notes/*)"],
      ...>     ask: %{"books/create_bill(amount >= 1000)" => "A bill this size needs a person."},
      ...>     deny: ["shell/*"]
      ...>   )
      iex> WardrikPolicy.decide(policy, "web_search")
      :allow
      iex> WardrikPolicy.decide(policy, "books__create_bill", arguments: %{"amount" => 9400})
      {:ask, "A bill this size needs a person."}
      iex> WardrikPolicy.explain(policy, "shell__exec")
      %WardrikPolicy.Decision{
        effect: :deny,
        message: "shell/exec is not allowed for this agent.",
        rule: "shell/*",
        cause: :rule
      }

  The strictest rule wins: deny, then ask, then allow.

  ## Keys

    * `:allow` - patterns that run.
    * `:ask` - patterns that wait for a person. A map of pattern to message sets the prompt.
    * `:deny` - patterns that are refused. A map of pattern to message sets the refusal.
    * `:allow_after` - a map of label to patterns that stay allowed after the run reads content
      with that label.
    * `:default` - for calls no rule names: `:allow`, `:ask`, `:deny`, or a list by annotation.
      `:allow` by default.
    * `:budget` - see `WardrikPolicy.Budget`.
    * `:judge` - see `WardrikPolicy.Judge`.

  ## Patterns

      "web_search"                            # one tool
      "github/*"                              # every tool from the github MCP server
      "write_file(notes/*)"                   # what the call acts on, given as :resources
      "books/create_bill(amount >= 1000)"     # an argument; =, !=, >, >=, < and <=
      "email/send(to != *@acme.com)"          # commas join conditions that must all hold

  An MCP tool named `github__create_issue` also matches as `github/create_issue`.

  ## Defaults by annotation

      iex> policy =
      ...>   WardrikPolicy.new!(
      ...>     allow: ["write_file(notes/*)"],
      ...>     default: [read_only: :allow, else: :ask]
      ...>   )
      iex> WardrikPolicy.decide(policy, "write_file", resources: ["secrets/key"])
      {:ask, "write_file needs your approval."}
      iex> WardrikPolicy.decide(policy, "read_file", annotations: %{read_only: true})
      :allow

  ## Policy files

      iex> {:ok, policy} =
      ...>   WardrikPolicy.decode(%{"deny" => ["email/send(to != *@acme.com)"], "default" => "ask"})
      iex> WardrikPolicy.decide(policy, "email__send", arguments: %{"to" => "x@evil.example"})
      {:deny, "email/send is not allowed for this agent."}

  ## Content from outside

  Once a run carries the `"outside"` label, a call to a tool annotated `gated: true` asks a person,
  even if a rule allows it. `allow_after` keeps it allowed:

      iex> policy =
      ...>   WardrikPolicy.new!(
      ...>     allow: ["linear/*"],
      ...>     allow_after: %{"outside" => ["github/add_labels"]}
      ...>   )
      iex> gated = %{gated: true}
      iex> WardrikPolicy.decide(policy, "linear__create_issue", annotations: gated, labels: ["outside"])
      {:ask, "linear/create_issue is allowed, but this run has read content from outside, which may be what asked for it."}
      iex> WardrikPolicy.decide(policy, "github__add_labels", annotations: gated, labels: ["outside"])
      :allow

  Any label `allow_after` names holds gated calls the same way.
  """

  alias WardrikPolicy.Budget
  alias WardrikPolicy.Call
  alias WardrikPolicy.Decision
  alias WardrikPolicy.Default
  alias WardrikPolicy.Judge
  alias WardrikPolicy.Read
  alias WardrikPolicy.Rules

  defstruct name: nil, rules: [], default: :allow, by_annotation: %{}, budget: nil, judge: nil

  @type t() :: %__MODULE__{
          name: String.t() | nil,
          rules: list(),
          default: effect(),
          by_annotation: %{String.t() => effect()},
          budget: Budget.t() | nil,
          judge: Judge.t() | nil
        }
  @type effect() :: :allow | :ask | :deny
  @type decision() :: :allow | {:ask, String.t()} | {:deny, String.t()}

  @keys ~w(allow allow_after ask deny default budget judge)

  @doc """
  Builds a policy from a keyword list or map. See the module docs for the keys.

      WardrikPolicy.new!([deny: ["shell/*"], budget: [usd: 5.00]], name: "acme")

  Raises `ArgumentError` if a rule, budget or judge can't be read.

  ## Options

    * `:name` - names the policy in each `WardrikPolicy.Decision`.
  """
  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(fields, opts \\ []) do
    fields =
      fields
      |> strings()
      |> Map.replace_lazy("budget", &budget/1)
      |> Map.replace_lazy("judge", &judge/1)

    case decode(fields, opts) do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Reads a policy from a map with string keys, such as parsed YAML. Takes `new!/2`'s options.

  Returns `{:error, message}` for an unknown key or a rule that can't be parsed.
  """
  @spec decode(map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def decode(fields, opts \\ [])

  def decode(fields, opts) when is_map(fields) do
    opts = Keyword.validate!(opts, [:name])

    with :ok <- Read.known(fields, @keys, "a policy"),
         {:ok, rules} <- Rules.decode(fields),
         {:ok, {default, by_annotation}} <- Default.decode(Map.get(fields, "default", :allow)),
         {:ok, budget} <- decoded(Budget, fields["budget"]),
         {:ok, judge} <- decoded(Judge, fields["judge"]) do
      {:ok,
       %__MODULE__{
         name: opts[:name],
         rules: rules,
         default: default,
         by_annotation: by_annotation,
         budget: budget,
         judge: judge
       }}
    end
  end

  def decode(_fields, _opts), do: {:error, "a policy is a map of allow, ask, deny and default"}

  @doc "Encodes a policy as the map `decode/2` reads, without its `:name`."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = policy) do
    %{
      "default" => Default.to_json(policy),
      "budget" => policy.budget && Budget.to_json(policy.budget),
      "judge" => policy.judge && Judge.to_json(policy.judge)
    }
    |> Map.merge(Rules.to_json(policy.rules))
    |> Read.present()
  end

  @doc """
  Decides a call to the tool `name`. Returns `:allow`, `{:ask, prompt}` or `{:deny, message}`.

  Given a list of policies, the strictest decision wins.

  ## Options

    * `:arguments` - the call's arguments, with string keys. `%{}` by default.
    * `:resources` - what the call acts on, such as file paths. `[]` by default.
    * `:annotations` - the tool's annotations, as `%{read_only: true}`. `%{}` by default.
    * `:labels` - labels for what the run has read, as `["outside"]`. `[]` by default.
    * `:evaluate` - asks a judge's model. See `t:WardrikPolicy.Judge.evaluate/0`.
  """
  @spec decide(t() | [t()], String.t(), keyword()) :: decision()
  def decide(policies, name, opts \\ []),
    do: policies |> explain(name, opts) |> Decision.outcome()

  @doc "Decides a call like `decide/3`, and returns a `WardrikPolicy.Decision` that says what decided."
  @spec explain(t() | [t()], String.t(), keyword()) :: Decision.t()
  def explain(policies, name, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        arguments: %{},
        resources: [],
        annotations: %{},
        labels: [],
        evaluate: nil
      )

    call = Call.new(name, opts)

    policies
    |> List.wrap()
    |> Enum.map(&verdict(&1, call))
    |> Decision.strictest()
  end

  defp verdict(policy, call) do
    %{policy | default: Default.for_tool(policy, call)}
    |> Rules.decide(call)
    |> Judge.weigh(policy.judge, call)
  end

  defp decoded(_module, nil), do: {:ok, nil}
  defp decoded(module, fields), do: module.decode(fields)

  defp budget(budget) do
    budget
    |> strings()
    |> Map.new(fn
      {key, value} when key in ["per", "on_exhausted"] and is_atom(value) and value != nil ->
        {key, Atom.to_string(value)}

      {key, value} when key in ["grant", "price"] ->
        {key, strings(value)}

      field ->
        field
    end)
  end

  defp judge(judge) do
    case strings(judge) do
      %{"questions" => questions} = judge when is_list(questions) ->
        %{judge | "questions" => Enum.map(questions, &strings/1)}

      judge ->
        judge
    end
  end

  defp strings(fields) do
    if (is_map(fields) and not is_struct(fields)) or Keyword.keyword?(fields),
      do: Map.new(fields, fn {key, value} -> {to_string(key), value} end),
      else: fields
  end
end
