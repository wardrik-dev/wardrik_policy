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
  """

  alias WardrikPolicy.Decision
  alias WardrikPolicy.Name
  alias WardrikPolicy.Pattern
  alias WardrikPolicy.Read
  alias WardrikPolicy.Rule

  defstruct name: nil, rules: [], default: :allow

  @type t() :: %__MODULE__{name: String.t() | nil, rules: [Rule.t()], default: Rule.effect()}
  @type decision() :: :allow | {:ask, String.t()} | {:deny, String.t()}

  @effects [:allow, :ask, :deny]
  @keys ~w(allow ask deny default)

  @doc "Builds a policy from a keyword list or map of rules. Raises if a rule doesn't read. Takes a `:name`."
  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(rules, opts \\ []) do
    case rules |> Map.new(fn {key, value} -> {to_string(key), value} end) |> decode(opts) do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Reads a policy from a map with string keys, like one parsed from a YAML file. Takes a `:name`."
  @spec decode(map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def decode(fields, opts \\ [])

  def decode(fields, opts) when is_map(fields) do
    opts = Keyword.validate!(opts, [:name])

    with :ok <- known_keys(fields),
         {:ok, rules} <- rules(fields),
         {:ok, default} <- default(Map.get(fields, "default", :allow)) do
      {:ok, %__MODULE__{name: opts[:name], rules: rules, default: default}}
    end
  end

  def decode(_fields, _opts), do: {:error, "a policy is a map of allow, ask, deny and default"}

  @doc """
  Decides a call to the tool `name`. Returns `:allow`, `{:ask, prompt}` or `{:deny, message}`.

  Pass the call's `:arguments`, the `:subjects` it acts on, and `gated: true` for a tool that
  changes things.
  """
  @spec decide(t() | [t()], String.t(), keyword()) :: decision()
  def decide(policies, name, opts \\ []),
    do: policies |> explain(name, opts) |> outcome()

  @doc """
  Like `decide/3`, but returns a `WardrikPolicy.Decision`, so you can see which rule decided.

  Give it a list of policies and the strictest decision wins. If any policy denies the call, it's
  denied. If any asks, it asks. A gated tool asks unless one of them allows it by name.
  """
  @spec explain(t() | [t()], String.t(), keyword()) :: Decision.t()
  def explain(policies, name, opts \\ []) do
    opts = Keyword.validate!(opts, arguments: %{}, subjects: [], gated: false)

    policies
    |> List.wrap()
    |> Enum.map(&verdict(&1, name, opts[:subjects], opts[:arguments]))
    |> strictest_decision()
    |> gate(opts[:gated], name)
  end

  defp strictest_decision([]), do: %Decision{effect: :allow, cause: :no_rule}

  defp strictest_decision(decisions), do: Enum.min_by(decisions, &rank/1)

  defp rank(decision), do: {strictness(decision.effect), by_default?(decision)}

  defp by_default?(decision), do: decision.cause != :rule
  defp outcome(%Decision{effect: :allow}), do: :allow
  defp outcome(%Decision{effect: effect, message: message}), do: {effect, message}

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

  defp gate(%Decision{effect: :allow, cause: :no_rule}, true, name),
    do: %Decision{
      effect: :ask,
      message: "#{Name.shown(name)} can change something.",
      cause: :gate
    }

  defp gate(decision, _gated?, _name), do: decision

  defp verdict(policy, name, subjects, arguments) do
    whole = rules_for_call(policy.rules, name, arguments)
    per_subject = Enum.map(subjects, &rules_for_subject(policy.rules, name, &1))

    case strictest(whole ++ Enum.concat(per_subject)) do
      nil -> by_default(policy, name)
      %Rule{effect: :allow} = rule -> allowed(policy, name, rule, {whole, per_subject})
      %Rule{} = rule -> by_rule(policy, rule, name)
    end
  end

  defp rules_for_call(rules, name, arguments),
    do: Enum.filter(rules, &Rule.whole?(&1, name, arguments))

  defp rules_for_subject(rules, name, subject),
    do: Enum.filter(rules, &Rule.subject?(&1, name, subject))

  defp strictest([]), do: nil
  defp strictest(rules), do: Enum.min_by(rules, fn rule -> strictness(rule.effect) end)

  @spec strictness(Rule.effect()) :: 0..2
  defp strictness(:deny), do: 0
  defp strictness(:ask), do: 1
  defp strictness(:allow), do: 2

  defp allowed(policy, name, rule, {whole, per_subject}) do
    if covered?(whole, per_subject),
      do: by_rule(policy, rule, name),
      else: by_default(policy, name)
  end

  defp covered?([_rule | _rules], _per_subject), do: true
  defp covered?([], []), do: false
  defp covered?([], per_subject), do: Enum.all?(per_subject, &(&1 != []))

  defp by_rule(policy, %Rule{effect: effect, message: message, pattern: pattern}, name) do
    %Decision{
      effect: effect,
      message: message || default_message(effect, name),
      rule: to_string(pattern),
      policy: policy.name,
      cause: :rule
    }
  end

  defp by_default(policy, name) do
    %Decision{
      effect: policy.default,
      message: default_message(policy.default, name),
      policy: policy.name,
      cause: :no_rule
    }
  end

  defp default_message(:allow, _name), do: nil
  defp default_message(:ask, name), do: "#{Name.shown(name)} needs your approval."
  defp default_message(:deny, name), do: "#{Name.shown(name)} is not allowed for this agent."

  defp known_keys(fields) do
    case Map.keys(fields) -- @keys do
      [] ->
        :ok

      [key | _keys] ->
        {:error, "#{key} is not a setting; expected one of #{Enum.join(@keys, ", ")}"}
    end
  end

  defp rules(fields) do
    @effects
    |> Enum.flat_map(&entries(fields, &1))
    |> Enum.map(fn {effect, entry} -> rule(effect, entry) end)
    |> Read.all()
  end

  defp entries(fields, effect) do
    fields
    |> Map.get(Atom.to_string(effect), [])
    |> listed()
    |> Enum.map(&{effect, &1})
  end

  defp listed(patterns) when is_list(patterns), do: Enum.map(patterns, &{&1, nil})
  defp listed(patterns) when is_map(patterns), do: Enum.to_list(patterns)
  defp listed(other), do: [{other, :not_a_list}]

  defp rule(effect, {_pattern, :not_a_list}),
    do: {:error, "#{effect} is a list of tool patterns, or a map of pattern to message"}

  defp rule(effect, {%{} = read, nil}) when map_size(read) == 1 do
    [{before, rest}] = Map.to_list(read)

    {:error,
     "#{effect} lists #{before}: #{rest}, which YAML reads as a key and its value; a condition " <>
       "on a value is written with =, and a rule with \": \" in it is quoted whole"}
  end

  defp rule(effect, {source, message}) when is_binary(message) or is_nil(message) do
    case Pattern.parse(source) do
      {:ok, pattern} -> {:ok, %Rule{effect: effect, pattern: pattern, message: message}}
      {:error, reason} -> {:error, "#{effect} names #{reason}"}
    end
  end

  defp rule(effect, {source, _message}),
    do: {:error, "#{effect} gives #{source} a message that is not text"}

  defp default(effect) when effect in @effects, do: {:ok, effect}
  defp default("allow"), do: {:ok, :allow}
  defp default("ask"), do: {:ok, :ask}
  defp default("deny"), do: {:ok, :deny}
  defp default(_value), do: {:error, "default is allow, ask or deny"}
end
