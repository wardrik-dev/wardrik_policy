defmodule WardrikPolicy.Ask do
  @moduledoc """
  An ask is the question a person answers before a call can run.

  Its `interrupt` is `"tool_approval"` for a tool call, or `"model_approval"` for a model call, and
  its `message` is the question. A park reason with those two keys is reported as an interrupt.
  """

  @enforce_keys [:interrupt, :message]
  defstruct [:interrupt, :message]

  @type t() :: %__MODULE__{interrupt: String.t(), message: String.t()}
end
