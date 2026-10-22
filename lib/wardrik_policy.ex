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

  A rule can also name what a call acts on, like a file's path. A gated tool is one that changes
  things, so it asks unless a rule allows it by name:

      iex> policy = WardrikPolicy.new!(allow: ["write_file(notes/*)"])
      iex> WardrikPolicy.decide(policy, "write_file", subjects: ["notes/today.md"], gated: true)
      :allow
      iex> WardrikPolicy.decide(policy, "write_file", subjects: ["secrets/key"], gated: true)
      {:ask, "write_file can change something."}

  Policy files work the same way. Parse the YAML into a map first:

      iex> {:ok, policy} =
      ...>   WardrikPolicy.decode(%{"deny" => ["email/send(to != *@acme.com)"], "default" => "ask"})
      iex> WardrikPolicy.decide(policy, "email__send", arguments: %{"to" => "x@evil.example"})
      {:deny, "email/send is not allowed for this agent."}
      iex> WardrikPolicy.decide(policy, "web_search")
      {:ask, "web_search needs your approval."}

  A policy can hold a budget too, which caps what the agent spends on model calls. See
  `WardrikPolicy.Budget`. And a judge, which asks a model about each call. See
  `WardrikPolicy.Judge`.
  """

  alias WardrikPolicy.Budget
  alias WardrikPolicy.Decision
  alias WardrikPolicy.Judge
  alias WardrikPolicy.Name
  alias WardrikPolicy.Rule
  alias WardrikPolicy.Rules

  defstruct name: nil, rules: [], default: :allow, budget: nil, judge: nil

  @type t() :: %__MODULE__{
          name: String.t() | nil,
          rules: [Rule.t()],
          default: Rule.effect(),
          budget: Budget.t() | nil,
          judge: Judge.t() | nil
        }
  @type decision() :: :allow | {:ask, String.t()} | {:deny, String.t()}

  @keys ~w(allow ask deny default)

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
         {:ok, default} <- default(Map.get(fields, "default", :allow)) do
      {:ok, %__MODULE__{name: opts[:name], rules: rules, default: default}}
    end
  end

  def decode(_fields, _opts), do: {:error, "a policy is a map of allow, ask, deny and default"}

  @doc """
  Decides a call to the tool `name`. Returns `:allow`, `{:ask, prompt}` or `{:deny, message}`.

  Pass the call's `:arguments`, the `:subjects` it acts on, and `gated: true` for a tool that
  changes things. A policy with a judge asks its model through `:evaluate`; see
  `t:WardrikPolicy.Judge.evaluate/0`.
  """
  @spec decide(t() | [t()], String.t(), keyword()) :: decision()
  def decide(policies, name, opts \\ []),
    do: policies |> explain(name, opts) |> Decision.outcome()

  @doc """
  Like `decide/3`, but returns a `WardrikPolicy.Decision`, so you can see which rule decided.

  Give it a list of policies and the strictest decision wins. If any policy denies the call, it's
  denied. If any asks, it asks. A gated tool asks unless one of them allows it by name.
  """
  @spec explain(t() | [t()], String.t(), keyword()) :: Decision.t()
  def explain(policies, name, opts \\ []) do
    opts = Keyword.validate!(opts, arguments: %{}, subjects: [], gated: false, evaluate: nil)

    policies
    |> List.wrap()
    |> Enum.map(&verdict(&1, name, opts))
    |> Decision.strictest()
    |> gate(opts[:gated], name)
  end

  if Code.ensure_loaded?(WardrikCore.Tool) do
    @doc """
    Tells `WardrikPolicy.Middleware` about a tool.

    Use `gated: true` for a tool that changes things. Use `subjects:` to say what a call acts on.
    It's a function of the call's arguments, like `fn args -> [args["path"]] end`.
    """
    @spec annotate(WardrikCore.Tool.t(), keyword()) :: WardrikCore.Tool.t()
    def annotate(%WardrikCore.Tool{} = tool, opts) do
      annotations = opts |> Keyword.validate!(gated: false, subjects: nil) |> Map.new()
      WardrikCore.Tool.put_private(tool, __MODULE__, annotations)
    end
  end

  defp verdict(policy, name, opts) do
    policy
    |> Rules.decide(name, opts[:subjects], opts[:arguments])
    |> Judge.weigh(policy.judge, name, opts)
  end

  defp gate(%Decision{effect: :allow, cause: :no_rule} = decision, true, name),
    do: %{
      decision
      | effect: :ask,
        message: "#{Name.shown(name)} can change something.",
        cause: :gate
    }

  defp gate(decision, _gated?, _name), do: decision

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

  defp default(effect) when effect in [:allow, :ask, :deny], do: {:ok, effect}
  defp default("allow"), do: {:ok, :allow}
  defp default("ask"), do: {:ok, :ask}
  defp default("deny"), do: {:ok, :deny}
  defp default(_value), do: {:error, "default is allow, ask or deny"}
end
