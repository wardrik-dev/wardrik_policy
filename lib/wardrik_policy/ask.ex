defmodule WardrikPolicy.Ask do
  @moduledoc "Why a tool call waits: the question a person is asked about it."

  @enforce_keys [:prompt]
  defstruct [:prompt]

  @type t() :: %__MODULE__{prompt: String.t()}
end
