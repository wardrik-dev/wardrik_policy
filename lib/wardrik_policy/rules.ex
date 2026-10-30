defmodule WardrikPolicy.Rules do
  @moduledoc false

  alias WardrikPolicy.Call
  alias WardrikPolicy.Decision
  alias WardrikPolicy.Name
  alias WardrikPolicy.Pattern
  alias WardrikPolicy.Read
  alias WardrikPolicy.Rule

  @effects [:allow, :ask, :deny]
  @outside "outside"

  @spec decide(WardrikPolicy.t(), Call.t()) :: Decision.t()
  def decide(policy, %Call{name: name} = call) do
    whole = Enum.filter(policy.rules, &Rule.whole?(&1, call))
    per_resource = Enum.map(call.resources, &for_resource(policy.rules, call, &1))

    case strictest(whole ++ Enum.concat(per_resource)) do
      nil -> by_default(policy, name)
      %Rule{effect: :allow} = rule -> allowed(policy, call, rule, {whole, per_resource})
      %Rule{} = rule -> named(policy, rule, name)
    end
  end

  @spec decode(map()) :: {:ok, [Rule.t()]} | {:error, String.t()}
  def decode(fields) do
    with {:ok, after_labels} <- after_labels(Map.get(fields, "allow_after", %{})) do
      @effects
      |> Enum.flat_map(&entries(fields, &1))
      |> Enum.concat(after_labels)
      |> Enum.map(fn {effect, entry} -> rule(effect, entry) end)
      |> Read.all()
    end
  end

  @spec to_json([Rule.t()]) :: map()
  def to_json(rules) do
    {after_label, rules} = Enum.split_with(rules, & &1.after)

    rules
    |> Enum.group_by(&Atom.to_string(&1.effect))
    |> patterns()
    |> Map.put("allow_after", after_label |> Enum.group_by(& &1.after) |> patterns())
  end

  defp patterns(groups), do: Map.new(groups, fn {key, rules} -> {key, written(rules)} end)

  defp written(rules) do
    if Enum.all?(rules, &is_nil(&1.message)),
      do: Enum.map(rules, &to_string(&1.pattern)),
      else: Map.new(rules, &{to_string(&1.pattern), &1.message})
  end

  defp for_resource(rules, call, resource),
    do: Enum.filter(rules, &Rule.resource?(&1, call, resource))

  defp strictest([]), do: nil
  defp strictest(rules), do: Enum.min_by(rules, &Decision.strictness(&1.effect))

  defp allowed(policy, call, rule, speaking) do
    if covered?(speaking, fn _rule -> true end),
      do: named_or_held(policy, call, rule, speaking),
      else: by_default(policy, call.name)
  end

  defp named_or_held(policy, call, rule, speaking) do
    case holding_label(policy, call, speaking) do
      nil -> named(policy, rule, call.name)
      label -> held(policy, rule, call.name, label)
    end
  end

  defp holding_label(policy, %Call{annotations: %{gated: true}, labels: labels}, speaking),
    do: Enum.find(labels, &(&1 in holding(policy) and not covered?(speaking, after?(&1))))

  defp holding_label(_policy, _call, _speaking), do: nil

  defp holding(policy),
    do: Enum.uniq([@outside | for(%Rule{after: label} <- policy.rules, label, do: label)])

  defp after?(label), do: &(&1.after == label)

  defp covered?({whole, per_resource}, test),
    do: Enum.any?(whole, test) or each_covered?(per_resource, test)

  defp each_covered?([], _test), do: false
  defp each_covered?(per_resource, test), do: Enum.all?(per_resource, &Enum.any?(&1, test))

  defp held(policy, %Rule{pattern: pattern}, name, label) do
    %Decision{
      effect: :ask,
      message:
        "#{Name.shown(name)} is allowed, but this run has read #{described(label)}, " <>
          "which may be what asked for it.",
      rule: to_string(pattern),
      policy: policy.name,
      cause: :label
    }
  end

  defp described(@outside), do: "content from outside"
  defp described(label), do: "content labelled #{label}"

  defp named(policy, %Rule{effect: effect, message: message, pattern: pattern}, name) do
    %Decision{
      effect: effect,
      message: message || said(effect, name),
      rule: to_string(pattern),
      policy: policy.name,
      cause: :rule
    }
  end

  defp by_default(policy, name) do
    %Decision{
      effect: policy.default,
      message: said(policy.default, name),
      policy: policy.name,
      cause: :no_rule
    }
  end

  defp said(:allow, _name), do: nil
  defp said(:ask, name), do: "#{Name.shown(name)} needs your approval."
  defp said(:deny, name), do: "#{Name.shown(name)} is not allowed for this agent."

  defp entries(fields, effect) do
    fields
    |> Map.get(Atom.to_string(effect), [])
    |> listed()
    |> Enum.map(&{effect, &1})
  end

  defp listed(patterns) when is_list(patterns), do: Enum.map(patterns, &{&1, nil})
  defp listed(patterns) when is_map(patterns), do: Enum.to_list(patterns)
  defp listed(other), do: [{other, :not_a_list}]

  defp after_labels(labels) when is_map(labels) do
    case Enum.reject(Map.keys(labels), &(is_binary(&1) and &1 != "")) do
      [] ->
        {:ok,
         for({label, patterns} <- labels, entry <- listed(patterns), do: {{:allow, label}, entry})}

      [label | _others] ->
        {:error, "allow_after names #{inspect(label)}, which is not a label"}
    end
  end

  defp after_labels(_other), do: {:error, "allow_after is a map of label to tool patterns"}

  defp rule({:allow, label}, entry) do
    with {:ok, rule} <- rule(:allow, entry), do: {:ok, %{rule | after: label}}
  end

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
end
