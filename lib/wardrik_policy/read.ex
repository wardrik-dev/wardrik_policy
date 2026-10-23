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

  @spec known(map(), [String.t()], String.t()) :: :ok | {:error, String.t()}
  def known(fields, keys, what) do
    case Map.keys(fields) -- keys do
      [] ->
        :ok

      [key | _keys] ->
        {:error, "#{key} is not a setting of #{what}; expected one of #{Enum.join(keys, ", ")}"}
    end
  end

  @spec choice(map(), String.t(), %{String.t() => atom()}, atom()) ::
          {:ok, atom()} | {:error, String.t()}
  def choice(fields, key, choices, default) do
    case Map.fetch(fields, key) do
      :error -> {:ok, default}
      {:ok, value} -> chosen(Map.fetch(choices, value), key, choices)
    end
  end

  @spec keywords(map() | nil, %{String.t() => atom()}, String.t()) ::
          {:ok, keyword() | nil} | {:error, String.t()}
  def keywords(nil, _keys, _what), do: {:ok, nil}

  def keywords(fields, keys, what) when is_map(fields) do
    with :ok <- known(fields, Map.keys(keys), what),
         do: {:ok, Enum.map(fields, fn {key, value} -> {Map.fetch!(keys, key), value} end)}
  end

  def keywords(_fields, keys, what),
    do: {:error, "#{what} is a map of #{names(keys)}"}

  defp chosen({:ok, atom}, _key, _choices), do: {:ok, atom}

  defp chosen(:error, key, choices),
    do: {:error, "#{key} is one of #{names(choices)}"}

  defp names(choices), do: Enum.map_join(choices, ", ", fn {name, _atom} -> name end)
end
