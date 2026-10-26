defmodule WardrikPolicy.Call do
  @moduledoc false

  @enforce_keys [:name]
  defstruct [:name, :evaluate, arguments: %{}, resources: [], annotations: %{}, labels: []]

  @type t() :: %__MODULE__{
          name: String.t(),
          arguments: map(),
          resources: [String.t()],
          annotations: map(),
          labels: [String.t()],
          evaluate: WardrikPolicy.Judge.evaluate() | nil
        }

  @spec new(String.t(), keyword()) :: t()
  def new(name, opts), do: struct!(__MODULE__, [{:name, name} | opts])
end
