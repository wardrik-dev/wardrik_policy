defmodule WardrikPolicy.Rule do
  @moduledoc false

  alias WardrikPolicy.Pattern

  @enforce_keys [:effect, :pattern]
  defstruct [:effect, :pattern, :message]

  @type effect() :: :allow | :ask | :deny
  @type t() :: %__MODULE__{effect: effect(), pattern: Pattern.t(), message: String.t() | nil}

  @spec whole?(t(), String.t(), map()) :: boolean()
  def whole?(%__MODULE__{pattern: pattern, effect: effect}, name, arguments) do
    case Pattern.whole(pattern, name, arguments) do
      :maybe -> effect != :allow
      held -> held
    end
  end

  @spec subject?(t(), String.t(), String.t()) :: boolean()
  def subject?(%__MODULE__{pattern: pattern}, name, subject),
    do: Pattern.match?(pattern, name, subject)
end
