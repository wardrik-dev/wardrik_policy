defmodule WardrikPolicy.Default do
  @moduledoc false

  alias WardrikPolicy.Call
  alias WardrikPolicy.Decision
  alias WardrikPolicy.Read

  @type effect() :: WardrikPolicy.effect()
  @type by_annotation() :: %{String.t() => effect()}

  @spec decode(term()) :: {:ok, {effect(), by_annotation()}} | {:error, String.t()}
  def decode(defaults) when is_map(defaults), do: defaults |> Map.to_list() |> decode()

  def decode([{_annotation, _effect} | _defaults] = defaults) do
    {fallback, by_annotation} =
      defaults
      |> Map.new(fn {annotation, effect} -> {to_string(annotation), effect} end)
      |> Map.pop("else", :allow)

    with {:ok, fallback} <- effect(fallback),
         {:ok, by_annotation} <- effects(by_annotation) do
      {:ok, {fallback, by_annotation}}
    end
  end

  def decode(effect) do
    with {:ok, effect} <- effect(effect), do: {:ok, {effect, %{}}}
  end

  @spec for_tool(WardrikPolicy.t(), Call.t()) :: effect()
  def for_tool(
        %WardrikPolicy{default: fallback, by_annotation: by_annotation},
        %Call{annotations: annotations}
      ) do
    by_annotation
    |> Map.take(held(annotations))
    |> Map.values()
    |> strictest(fallback)
  end

  defp held(annotations), do: for({annotation, true} <- annotations, do: to_string(annotation))

  defp strictest([], fallback), do: fallback
  defp strictest(effects, _fallback), do: Enum.min_by(effects, &Decision.strictness/1)

  defp effects(by_annotation) do
    with {:ok, pairs} <- by_annotation |> Enum.map(&annotated/1) |> Read.all(),
         do: {:ok, Map.new(pairs)}
  end

  defp annotated({annotation, effect}) do
    case effect(effect) do
      {:ok, effect} -> {:ok, {annotation, effect}}
      {:error, _message} -> {:error, not_an_effect(annotation, effect)}
    end
  end

  defp not_an_effect(annotation, effect),
    do: "default gives #{annotation} #{inspect(effect)}, which is not allow, ask or deny"

  defp effect(effect) when effect in [:allow, :ask, :deny], do: {:ok, effect}
  defp effect("allow"), do: {:ok, :allow}
  defp effect("ask"), do: {:ok, :ask}
  defp effect("deny"), do: {:ok, :deny}

  defp effect(_value),
    do: {:error, "default is allow, ask or deny, or a map of annotation to one of them"}
end
