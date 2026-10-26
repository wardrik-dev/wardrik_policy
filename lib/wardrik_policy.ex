defmodule WardrikPolicy do
  @moduledoc """
  A policy decides each tool call an agent makes. It runs the call, asks a person first, or refuses it.

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

  The strictest rule wins. A deny beats an ask, and an ask beats an allow.

  A rule can also name what a call acts on, like a file's path. A call no rule names follows the
  `default`, which can turn on the tool's annotations, like `read_only`:

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

  Policy files work the same way. Parse the YAML into a map first:

      iex> {:ok, policy} =
      ...>   WardrikPolicy.decode(%{"deny" => ["email/send(to != *@acme.com)"], "default" => "ask"})
      iex> WardrikPolicy.decide(policy, "email__send", arguments: %{"to" => "x@evil.example"})
      {:deny, "email/send is not allowed for this agent."}
      iex> WardrikPolicy.decide(policy, "web_search")
      {:ask, "web_search needs your approval."}

  Once a run has read content from outside, such as a web page or a search result, a gated tool's
  call waits for a person however the rules allow it, since what the run read may be what asked for
  it. Pass the run's labels as `:labels`. `allow_after` allows a call by name as `allow` does, and
  holds after its label too, for tools a stranger can't misuse:

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

  A label `allow_after` names holds gated calls the way `outside` does. One no rule names holds
  nothing.

  A policy can hold a budget too, which caps what the agent spends on model calls. See
  `WardrikPolicy.Budget`. And a judge, which asks a model about each call. See
  `WardrikPolicy.Judge`.
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
  Builds a policy from a keyword list or map of rules, a `budget:` and a `judge:`. See
  `WardrikPolicy.Budget` and `WardrikPolicy.Judge`. Raises if a rule doesn't read. Takes a `:name`.
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

  @doc "Reads a policy from a map with string keys, like one parsed from a YAML file. Takes a `:name`."
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

  Pass the call's `:arguments`, the `:resources` it acts on, the tool's `:annotations`, like
  `%{read_only: true}`, and the `:labels` of what its run has read. A policy with a judge asks its model through `:evaluate`; see
  `t:WardrikPolicy.Judge.evaluate/0`.
  """
  @spec decide(t() | [t()], String.t(), keyword()) :: decision()
  def decide(policies, name, opts \\ []),
    do: policies |> explain(name, opts) |> Decision.outcome()

  @doc """
  Like `decide/3`, but returns a `WardrikPolicy.Decision`, so you can see which rule decided.

  Give it a list of policies and the strictest decision wins. If any policy denies the call, it's
  denied. If any asks, it asks.
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
