defmodule WardrikPolicy.Ask do
  @moduledoc """
  What a call waits on when a policy asks. `WardrikPolicy.Middleware` parks on it.

    * `:interrupt` - `"tool_approval"` or `"model_approval"`.
    * `:message` - the prompt for the person.
    * `:labels` - labels for what the run had read.
    * `:call` - the tool call it decided, or `nil` for a model call. A call made inside another,
      such as a coding agent's request, is that call, not the one that parked.
  """

  @enforce_keys [:interrupt, :message]
  defstruct [:interrupt, :message, :call, labels: []]

  @type t() :: %__MODULE__{
          interrupt: String.t(),
          message: String.t(),
          call: WardrikCore.ToolCall.t() | nil,
          labels: [String.t()]
        }
end
