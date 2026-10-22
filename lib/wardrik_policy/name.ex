defmodule WardrikPolicy.Name do
  @moduledoc false

  @type glob() :: [String.t()]

  @spec glob(String.t()) :: glob()
  def glob(source), do: String.split(source, "*")

  @spec shown(String.t()) :: String.t()
  def shown(name), do: String.replace(name, "__", "/", global: false)

  @spec match?(glob(), String.t()) :: boolean()
  def match?(glob, name), do: glob?(glob, name) or glob?(glob, shown(name))

  @spec glob?(glob(), String.t()) :: boolean()
  def glob?([whole], text), do: text == whole

  def glob?([first | rest], text) do
    String.starts_with?(text, first) and
      follows?(rest, binary_slice(text, byte_size(first)..-1//1))
  end

  defp follows?([last], rest), do: String.ends_with?(rest, last)
  defp follows?(["" | parts], rest), do: follows?(parts, rest)

  defp follows?([part | parts], rest) do
    case :binary.match(rest, part) do
      {at, length} -> follows?(parts, binary_slice(rest, (at + length)..-1//1))
      :nomatch -> false
    end
  end
end
