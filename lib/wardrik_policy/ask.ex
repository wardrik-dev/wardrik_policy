defmodule WardrikPolicy.Ask do
  @moduledoc """
  An ask is the question a person answers before a call can run.
  """

  @enforce_keys [:interrupt, :message]
  defstruct [:interrupt, :message]

  @type t() :: %__MODULE__{interrupt: String.t(), message: String.t()}
end
