defmodule WardrikPolicy.Decision do
  @moduledoc """
  A decision is what a policy said about a call, and its cause.

  The cause is `:rule` when a rule named the call, and `rule` holds that rule. It's `:gate` when
  a gated tool asked because no rule allowed it by name. It's `:no_rule` when no rule covered the
  whole call, so the policy's `default:` decided.
  """

  @enforce_keys [:effect, :cause]
  defstruct [:effect, :message, :rule, :cause]

  @type t() :: %__MODULE__{
          effect: :allow | :ask | :deny,
          message: String.t() | nil,
          rule: String.t() | nil,
          cause: :rule | :gate | :no_rule
        }
end
