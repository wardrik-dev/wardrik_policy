defmodule WardrikPolicy.Ask do
  @moduledoc """
  The question a person answers before a call can run. `WardrikPolicy.Middleware` parks on it.

    * `:interrupt` - `"tool_approval"` or `"model_approval"`.
    * `:message` - the prompt for the person.
    * `:labels` - labels for what the run had read, which may be what asked for the call.
  """

  @enforce_keys [:interrupt, :message]
  defstruct [:interrupt, :message, labels: []]

  @type t() :: %__MODULE__{interrupt: String.t(), message: String.t(), labels: [String.t()]}
end
