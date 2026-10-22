defmodule WardrikPolicy.Read do
  @moduledoc false

  @spec all([{:ok, value} | {:error, String.t()}]) :: {:ok, [value]} | {:error, String.t()}
        when value: term()
  def all(results) do
    case Enum.find(results, &match?({:error, _message}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, value} -> value end)}
      error -> error
    end
  end
end
