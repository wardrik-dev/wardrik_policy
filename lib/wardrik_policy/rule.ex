defmodule WardrikPolicy.Rule do
  @moduledoc false

  alias WardrikPolicy.Call
  alias WardrikPolicy.Pattern

  @enforce_keys [:effect, :pattern]
  defstruct [:effect, :pattern, :message]

  @type effect() :: :allow | :ask | :deny
  @type t() :: %__MODULE__{effect: effect(), pattern: Pattern.t(), message: String.t() | nil}

  @spec whole?(t(), Call.t()) :: boolean()
  def whole?(%__MODULE__{pattern: pattern, effect: effect}, %Call{} = call) do
    case Pattern.whole(pattern, call.name, call.arguments) do
      :maybe -> effect != :allow
      held -> held
    end
  end

  @spec resource?(t(), Call.t(), String.t()) :: boolean()
  def resource?(%__MODULE__{pattern: pattern}, %Call{name: name}, resource),
    do: Pattern.match?(pattern, name, resource)
end
