defmodule WardrikPolicy.Condition do
  @moduledoc false

  alias WardrikPolicy.Name
  alias WardrikPolicy.Read

  @enforce_keys [:path, :test]
  defstruct [:path, :test]

  @type test() ::
          {:is | :is_not, [String.t()], number() | nil}
          | {:gt | :ge | :lt | :le, number()}

  @type t() :: %__MODULE__{path: [String.t()], test: test()}

  @type held() :: boolean() | :maybe

  @condition ~r/\A([A-Za-z_][\w-]*(?:\.[\w-]+)*)\s*(==|>=|<=|!=|=|>|<|:(?=\s|"|\z))\s*(.*)\z/su
  @comparisons %{">" => :gt, ">=" => :ge, "<" => :lt, "<=" => :le}
  @syntax "conditions go as name = value, name != value or name > number, comma-separated, as " <>
            "books/create_bill(amount > 500, account = Payroll)"
  @mixed "puts conditions beside what a call acts on; the parentheses hold one or the other: " <>
           "what a call acts on, as write_file(notes/*), or #{@syntax}"

  @spec parse(String.t()) :: {:ok, [t()]} | :resource | {:error, String.t()}
  def parse(text) do
    text
    |> pieces()
    |> Enum.map(&read/1)
    |> classify()
  end

  defp read(piece), do: Regex.run(@condition, String.trim(piece), capture: :all_but_first)

  defp classify(read), do: read |> Enum.split_with(&is_nil/1) |> classified()

  defp classified({_resources, []}), do: :resource
  defp classified({[], conditions}), do: conditions |> Enum.map(&condition/1) |> Read.all()
  defp classified(_mixed), do: {:error, @mixed}

  defp condition([path, ":", value]),
    do: {:error, "writes #{path}: #{value}; a condition on a value is #{path} = #{value}"}

  defp condition([path, "==", value]),
    do: {:error, "writes #{path} == #{value}; a condition on a value is #{path} = #{value}"}

  defp condition([path, operator, value]) when operator in ["=", "!="] do
    with {:ok, text} <- value(path, value) do
      test = {equality(operator), glob(text), literal_number(value, text)}
      {:ok, %__MODULE__{path: String.split(path, "."), test: test}}
    end
  end

  defp condition([path, operator, value]) do
    case number(value) do
      nil ->
        {:error, not_a_number(path, value)}

      number ->
        {:ok, %__MODULE__{path: String.split(path, "."), test: {comparison(operator), number}}}
    end
  end

  defp equality("="), do: :is
  defp equality("!="), do: :is_not

  defp comparison(operator), do: Map.fetch!(@comparisons, operator)

  defp glob(text), do: text |> String.downcase() |> Name.glob()

  defp literal_number("\"" <> _quoted, _text), do: nil
  defp literal_number(_value, text), do: number(text)

  defp not_a_number(path, value),
    do:
      "compares #{path} with #{inspect(value)}, which is not a number; " <>
        ">, >=, < and <= take one, as amount > 500"

  defp value(path, "\"" <> rest = value) do
    case String.split(rest, "\"") do
      [text, ""] -> {:ok, text}
      _other -> {:error, "gives #{path} #{value}, which is not one value in double quotes"}
    end
  end

  defp value(path, ""),
    do: {:error, "gives #{path} no value; #{@syntax}"}

  defp value(path, value) do
    if String.contains?(value, "\""),
      do: {:error, "gives #{path} #{value}; a value in double quotes is quoted whole"},
      else: {:ok, value}
  end

  defp pieces(text), do: pieces(text, "", false, [])

  defp pieces(<<>>, piece, _quoted?, pieces), do: Enum.reverse([piece | pieces])

  defp pieces(<<?,, rest::binary>>, piece, false, pieces),
    do: pieces(rest, "", false, [piece | pieces])

  defp pieces(<<?", rest::binary>>, piece, quoted?, pieces),
    do: pieces(rest, piece <> "\"", not quoted?, pieces)

  defp pieces(<<byte, rest::binary>>, piece, quoted?, pieces),
    do: pieces(rest, <<piece::binary, byte>>, quoted?, pieces)

  defp number(text) do
    text = String.trim(text)

    case Integer.parse(text) do
      {integer, ""} ->
        integer

      _other ->
        case Float.parse(text) do
          {float, ""} -> float
          _other -> nil
        end
    end
  end

  @spec held([t()], map()) :: held()
  def held(conditions, arguments) do
    Enum.reduce_while(conditions, true, fn condition, held ->
      case check(arguments, condition.path, condition.test) do
        false -> {:halt, false}
        true -> {:cont, held}
        :maybe -> {:cont, :maybe}
      end
    end)
  end

  defp check(nil, _path, _test), do: false

  defp check(items, path, test) when is_list(items),
    do: each(Enum.map(items, &check(&1, path, test)))

  defp check(%{} = object, [key | path], test), do: check(Map.get(object, key), path, test)
  defp check(%{}, [], _test), do: :maybe
  defp check(_value, [_key | _path], _test), do: :maybe
  defp check(value, [], test), do: test(test, value)

  defp each([]), do: false

  defp each(held) do
    cond do
      Enum.all?(held, &(&1 == true)) -> true
      Enum.all?(held, &(&1 == false)) -> false
      true -> :maybe
    end
  end

  defp test({:is_not, glob, number}, value)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: not test({:is, glob, number}, value)

  defp test({:is, _glob, number}, value) when is_number(value) and is_number(number),
    do: value == number

  defp test({:is, glob, number}, value) when is_binary(value) do
    case is_number(number) && number(value) do
      read when is_number(read) -> read == number
      _text -> Name.glob?(glob, String.downcase(value))
    end
  end

  defp test({:is, glob, _number}, value) when is_number(value) or is_boolean(value),
    do: Name.glob?(glob, to_string(value))

  defp test({comparison, number}, value) when is_number(value),
    do: compare(comparison, value, number)

  defp test({comparison, number}, value) when is_binary(value) do
    case number(value) do
      nil -> :maybe
      read -> compare(comparison, read, number)
    end
  end

  defp test(_test, _value), do: :maybe

  defp compare(:gt, value, number), do: value > number
  defp compare(:ge, value, number), do: value >= number
  defp compare(:lt, value, number), do: value < number
  defp compare(:le, value, number), do: value <= number
end
