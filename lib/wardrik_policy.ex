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
      iex> WardrikPolicy.decide(policy, "shell__exec")
      {:deny, "shell/exec is not allowed for this agent."}
      iex> WardrikPolicy.explain(policy, "shell__exec")
      %WardrikPolicy.Decision{
        effect: :deny,
        message: "shell/exec is not allowed for this agent.",
        rule: "shell/*",
        cause: :rule
      }

  The strictest rule wins: deny, then ask, then allow.

  ## Rules

    * `:allow` - tool patterns that run.
    * `:ask` - tool patterns that wait for a person. A map of pattern to message sets the prompt.
    * `:deny` - tool patterns that are refused. A map of pattern to message sets the refusal.
    * `:allow_after` - a map of label to patterns that stay allowed after the run reads content
      with that label. See "Content from outside" below.
    * `:default` - what a call no rule names gets: `:allow`, `:ask`, `:deny`, or a map by
      annotation. `:allow` unless set.
    * `:budget` - caps what the agent spends on model calls. See `WardrikPolicy.Budget`.
    * `:judge` - asks a model about each call. See `WardrikPolicy.Judge`.

  A pattern names a tool, what the call acts on, or its arguments:

      "web_search"                            # one tool
      "github/*"                              # every tool from the github MCP server
      "write_file(notes/*)"                   # what the call acts on, given as :resources
      "books/create_bill(amount >= 1000)"     # an argument; =, !=, >, >=, < and <=
      "email/send(to != *@acme.com)"          # a comma means all conditions must hold

  An MCP tool named `github__create_issue` also matches as `github/create_issue`.

  ## Defaults by annotation

  A call no rule names follows `:default`. The default can depend on the tool's annotations:

      iex> policy =
      ...>   WardrikPolicy.new!(
      ...>     allow: ["write_file(notes/*)"],
      ...>     default: [read_only: :allow, else: :ask]
      ...>   )
      iex> WardrikPolicy.decide(policy, "write_file", resources: ["notes/today.md"])
      :allow
      iex> WardrikPolicy.decide(policy, "write_file", resources: ["secrets/key"])
      {:ask, "write_file needs your approval."}
      iex> WardrikPolicy.decide(policy, "read_file", annotations: %{read_only: true})
      :allow

  When a tool has several annotations, the strictest wins. `else` covers a tool with none of them,
  and is `:allow` unless set.

  ## Policy files

  Parse the YAML into a map, then call `decode/2`:

      iex> {:ok, policy} =
      ...>   WardrikPolicy.decode(%{"deny" => ["email/send(to != *@acme.com)"], "default" => "ask"})
      iex> WardrikPolicy.decide(policy, "email__send", arguments: %{"to" => "x@evil.example"})
      {:deny, "email/send is not allowed for this agent."}
      iex> WardrikPolicy.decide(policy, "web_search")
      {:ask, "web_search needs your approval."}

  ## Content from outside

  A run that has read content from outside, such as a web page, may have been told what to call.
  So once a run carries the `"outside"` label, a call to a gated tool asks a person, even if a rule
  allows it. Pass the run's labels as `:labels`. `allow_after` keeps a call allowed for tools a
  stranger can't misuse:

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

  A tool is gated when its annotations include `gated: true`. Any label that `allow_after` names
  holds gated calls the same way `"outside"` does. Other labels hold nothing.
  """

  alias WardrikPolicy.Budget
  alias WardrikPolicy.Call
  alias WardrikPolicy.Decision
  alias WardrikPolicy.Default
  alias WardrikPolicy.Judge
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

  Raises `ArgumentError` if a rule can't be parsed.

  ## Options

    * `:name` - names the policy in each `WardrikPolicy.Decision`. `nil` unless set.
  """
  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(fields, opts \\ []) do
    fields = Map.new(fields, fn {key, value} -> {to_string(key), value} end)
    {budget, fields} = Map.pop(fields, "budget")
    {judge, rules} = Map.pop(fields, "judge")

    case decode(rules, opts) do
      {:ok, policy} -> %{policy | budget: build(Budget, budget), judge: build(Judge, judge)}
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Reads a policy from a map with string keys, such as one parsed from YAML.

  Returns `{:error, message}` for an unknown key or a rule that can't be parsed. Takes the same
  options as `new!/2`.
  """
  @spec decode(map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def decode(fields, opts \\ [])

  def decode(fields, opts) when is_map(fields) do
    opts = Keyword.validate!(opts, [:name])

    with :ok <- known_keys(fields),
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

  @doc """
  Decides a call to the tool `name`. Returns `:allow`, `{:ask, prompt}` or `{:deny, message}`.

  Given a list of policies, the strictest decision wins.

  ## Options

    * `:arguments` - the call's arguments, as a map with string keys. `%{}` unless set.
    * `:resources` - what the call acts on, such as file paths. `[]` unless set.
    * `:annotations` - the tool's annotations, as `%{read_only: true}`. `%{}` unless set.
    * `:labels` - labels for what the run has read, as `["outside"]`. `[]` unless set.
    * `:evaluate` - asks a judge's model. See `t:WardrikPolicy.Judge.evaluate/0`.
  """
  @spec decide(t() | [t()], String.t(), keyword()) :: decision()
  def decide(policies, name, opts \\ []),
    do: policies |> explain(name, opts) |> Decision.outcome()

  @doc """
  Decides a call like `decide/3`, but returns a `WardrikPolicy.Decision` that says what decided.

  Given a list of policies, the strictest decision wins. If any policy denies the call, it's
  denied. Otherwise, if any asks, it asks.
  """
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

  defp build(_module, nil), do: nil
  defp build(module, opts), do: struct!(module, opts)

  defp known_keys(fields) do
    case Map.keys(fields) -- @keys do
      [] ->
        :ok

      [key | _keys] ->
        {:error, "#{key} is not a setting; expected one of #{Enum.join(@keys, ", ")}"}
    end
  end
end
