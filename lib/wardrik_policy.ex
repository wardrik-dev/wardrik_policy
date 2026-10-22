defmodule WardrikPolicy do
  @moduledoc """
  Rules that decide every tool call an agent makes: run it, ask a person first, or refuse it.

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

  A rule can name what a call acts on, and a gated tool asks unless a rule allows it by name:

      iex> policy = WardrikPolicy.new!(allow: ["write_file(notes/*)"])
      iex> WardrikPolicy.decide(policy, "write_file", subjects: ["notes/today.md"], gated: true)
      :allow
      iex> WardrikPolicy.decide(policy, "write_file", subjects: ["secrets/key"], gated: true)
      {:ask, "write_file can change something."}

  A policy file reads the same way, once parsed into a map:

      iex> {:ok, policy} =
      ...>   WardrikPolicy.decode(%{"deny" => ["email/send(to != *@acme.com)"], "default" => "ask"})
      iex> WardrikPolicy.decide(policy, "email__send", arguments: %{"to" => "x@evil.example"})
      {:deny, "email/send is not allowed for this agent."}
      iex> WardrikPolicy.decide(policy, "web_search")
      {:ask, "web_search needs your approval."}
  """

  alias WardrikPolicy.Name
  alias WardrikPolicy.Pattern
  alias WardrikPolicy.Read
  alias WardrikPolicy.Rule

  defstruct rules: [], default: :allow

  @type t() :: %__MODULE__{rules: [Rule.t()], default: Rule.effect()}
  @type decision() :: :allow | {:ask, String.t()} | {:deny, String.t()}

  @effects [:allow, :ask, :deny]
  @keys ~w(allow ask deny default)
  @strictness %{deny: 2, ask: 1, allow: 0}

  @doc "The policy `rules` write, as a keyword list or a map, raising where they write none."
  @spec new!(keyword() | map()) :: t()
  def new!(rules) do
    case rules |> Map.new(fn {key, value} -> {to_string(key), value} end) |> decode() do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "The policy a map with string keys writes, as a file does."
  @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
  def decode(fields) when is_map(fields) do
    with :ok <- known_keys(fields),
         {:ok, rules} <- rules(fields),
         {:ok, default} <- default(Map.get(fields, "default", :allow)) do
      {:ok, %__MODULE__{rules: rules, default: default}}
    end
  end

  def decode(_fields), do: {:error, "a policy is a map of allow, ask, deny and default"}

  @doc """
  What `policy` says about a call to the tool `name`.
  """
  @spec decide(t(), String.t(), keyword()) :: decision()
  def decide(%__MODULE__{} = policy, name, opts \\ []) do
    opts = Keyword.validate!(opts, arguments: %{}, subjects: [], gated: false)

    case verdict(policy, name, opts[:subjects], opts[:arguments]) do
      {:allow, :named} -> :allow
      {:allow, :default} -> gate(opts[:gated], name)
      decision -> decision
    end
  end

  if Code.ensure_loaded?(WardrikCore.Tool) do
    @doc """
    Marks `tool` for `WardrikPolicy.Middleware`: `gated: true` asks unless a rule allows it by
    name, and `subjects:`, a function of the call's arguments, names what a call acts on.
    """
    @spec annotate(WardrikCore.Tool.t(), keyword()) :: WardrikCore.Tool.t()
    def annotate(%WardrikCore.Tool{} = tool, opts) do
      annotations = opts |> Keyword.validate!(gated: false, subjects: nil) |> Map.new()
      WardrikCore.Tool.put_private(tool, __MODULE__, annotations)
    end
  end

  defp gate(true, name), do: {:ask, "#{Name.shown(name)} can change something."}
  defp gate(false, _name), do: :allow

  defp verdict(policy, name, subjects, arguments) do
    whole = rules_for_call(policy.rules, name, arguments)
    per_subject = Enum.map(subjects, &rules_for_subject(policy.rules, name, &1))

    case strictest(whole ++ Enum.concat(per_subject)) do
      nil -> answer(policy.default, nil, name)
      %Rule{effect: :allow} -> allowed(policy, name, whole, per_subject)
      %Rule{effect: effect, message: message} -> answer(effect, message, name)
    end
  end

  defp rules_for_call(rules, name, arguments),
    do: Enum.filter(rules, &Rule.whole?(&1, name, arguments))

  defp rules_for_subject(rules, name, subject),
    do: Enum.filter(rules, &Rule.subject?(&1, name, subject))

  defp strictest([]), do: nil
  defp strictest(rules), do: Enum.max_by(rules, &Map.fetch!(@strictness, &1.effect))

  defp allowed(policy, name, whole, per_subject) do
    if covered?(whole, per_subject),
      do: {:allow, :named},
      else: answer(policy.default, nil, name)
  end

  defp covered?([_rule | _rules], _per_subject), do: true
  defp covered?([], []), do: false
  defp covered?([], per_subject), do: Enum.all?(per_subject, &(&1 != []))

  defp answer(:allow, _message, _name), do: {:allow, :default}

  defp answer(:ask, message, name),
    do: {:ask, message || "#{Name.shown(name)} needs your approval."}

  defp answer(:deny, message, name),
    do: {:deny, message || "#{Name.shown(name)} is not allowed for this agent."}

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
