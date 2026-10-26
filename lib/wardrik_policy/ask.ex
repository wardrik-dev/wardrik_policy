defmodule WardrikPolicy.Ask do
  @moduledoc """
  An ask is the question a person answers before a call can run, with the labels of what its run
  had read, which may be what asked for the call.
  """

  @enforce_keys [:interrupt, :message]
  defstruct [:interrupt, :message, labels: []]

  @type t() :: %__MODULE__{interrupt: String.t(), message: String.t(), labels: [String.t()]}
end
