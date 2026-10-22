defmodule WardrikPolicy.Rules do
  @moduledoc false

  alias WardrikPolicy.Decision
  alias WardrikPolicy.Name
  alias WardrikPolicy.Pattern
  alias WardrikPolicy.Read
  alias WardrikPolicy.Rule

  @effects [:allow, :ask, :deny]

  @spec decide(WardrikPolicy.t(), String.t(), [String.t()], map()) :: Decision.t()
  def decide(policy, name, subjects, arguments) do
    whole = Enum.filter(policy.rules, &Rule.whole?(&1, name, arguments))
    per_subject = Enum.map(subjects, &for_subject(policy.rules, name, &1))

    case strictest(whole ++ Enum.concat(per_subject)) do
      nil -> by_default(policy, name)
      %Rule{effect: :allow} = rule -> allowed(policy, name, rule, {whole, per_subject})
      %Rule{} = rule -> named(policy, rule, name)
    end
  end

  @spec decode(map()) :: {:ok, [Rule.t()]} | {:error, String.t()}
  def decode(fields) do
    @effects
    |> Enum.flat_map(&entries(fields, &1))
    |> Enum.map(fn {effect, entry} -> rule(effect, entry) end)
    |> Read.all()
  end

  defp for_subject(rules, name, subject),
    do: Enum.filter(rules, &Rule.subject?(&1, name, subject))

  defp strictest([]), do: nil
  defp strictest(rules), do: Enum.min_by(rules, &Decision.strictness(&1.effect))

  defp allowed(policy, name, rule, {whole, per_subject}) do
    if covered?(whole, per_subject),
      do: named(policy, rule, name),
      else: by_default(policy, name)
  end

  defp covered?([_rule | _rules], _per_subject), do: true
  defp covered?([], []), do: false
  defp covered?([], per_subject), do: Enum.all?(per_subject, &(&1 != []))

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
