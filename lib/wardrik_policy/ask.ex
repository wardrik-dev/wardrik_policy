defmodule WardrikPolicy.Ask do
  @moduledoc "An ask is the question a person answers before a call can run."

  @enforce_keys [:prompt]
  defstruct [:prompt]

  @type t() :: %__MODULE__{prompt: String.t()}
end
