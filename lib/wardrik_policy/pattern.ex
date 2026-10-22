defmodule WardrikPolicy.Pattern do
  @moduledoc false

  alias WardrikPolicy.Condition
  alias WardrikPolicy.Name

  @enforce_keys [:source, :parts]
  defstruct [:source, :parts, :argument, :conditions]

  @type t() :: %__MODULE__{
          source: String.t(),
          parts: [String.t()],
          argument: [String.t()] | nil,
          conditions: [Condition.t()] | nil
        }

  @call ~r/\A([^()]+)\((.*)\)\z/s
  @list_hint "a [ ] list splits a rule at its commas, so quote a rule with several conditions " <>
               "there, as \"tool(a > 1, b = 2)\", or write the rules one to a line, each after a -"

  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(source) when is_binary(source) and source != "" do
    case Regex.run(@call, source, capture: :all_but_first) do
      [name, inner] -> source |> new(name) |> with_argument(inner)
      nil -> plain(source)
    end
  end

  def parse(source), do: {:error, "#{inspect(source)} is not a tool pattern"}

  defp new(source, name), do: %__MODULE__{source: source, parts: Name.glob(name)}

  defp with_argument(pattern, inner) do
    case Condition.parse(inner) do
      :resource -> {:ok, %{pattern | argument: Name.glob(inner)}}
      {:ok, conditions} -> {:ok, %{pattern | conditions: conditions}}
      {:error, message} -> {:error, "#{inspect(pattern.source)}, which #{message}"}
    end
  end

  defp plain(source) do
    case {count(source, "("), count(source, ")")} do
      {0, 0} -> {:ok, new(source, source)}
      {same, same} -> {:error, misplaced(source)}
      {opened, closed} -> {:error, unbalanced(source, opened > closed)}
    end
  end

  defp count(source, character), do: source |> :binary.matches(character) |> length()

  defp misplaced(source),
    do:
      "#{inspect(source)}, which is not a tool pattern; what a call acts on goes in " <>
        "parentheses after the tool, as shell(git status)"

  defp unbalanced(source, opened?) do
    what =
      if opened?,
        do: "opens a parenthesis it never closes",
        else: "closes a parenthesis it never opens"

    "#{inspect(source)}, which #{what}; #{@list_hint}"
  end

  @spec argument?(t()) :: boolean()
  def argument?(%__MODULE__{argument: argument, conditions: conditions}),
    do: argument != nil or conditions != nil

  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{} = pattern, name), do: not argument?(pattern) and names?(pattern, name)

  @spec whole(t(), String.t(), map()) :: Condition.held()
  def whole(%__MODULE__{argument: nil, conditions: nil} = pattern, name, _arguments),
    do: names?(pattern, name)

  def whole(%__MODULE__{argument: nil, conditions: conditions} = pattern, name, arguments),
    do: names?(pattern, name) and Condition.held(conditions, arguments)

  def whole(%__MODULE__{}, _name, _arguments), do: false

  @spec match?(t(), String.t(), String.t()) :: boolean()
  def match?(%__MODULE__{argument: nil}, _name, _resource), do: false

  def match?(%__MODULE__{argument: argument} = pattern, name, resource),
    do: names?(pattern, name) and Name.glob?(argument, resource)

  defp names?(%__MODULE__{parts: parts}, name), do: Name.match?(parts, name)

  defimpl String.Chars do
    def to_string(pattern), do: pattern.source
  end
end
