defmodule WardrikPolicy.Decision do
  @moduledoc """
  A decision is what a policy said about a call, and its cause.

  `policy` names the policy that decided, when it has a name. The cause is `:rule` when a rule
  named the call, and `rule` holds that rule. It's `:gate` when
  a gated tool asked because no rule allowed it by name. It's `:no_rule` when no rule covered the
  whole call, so the policy's `default:` decided. It's `:judge` when the policy's judge decided, and
  `:budget` when a model call reached the policy's budget.
  """

  @enforce_keys [:effect, :cause]
  defstruct [:effect, :message, :rule, :policy, :cause]

  @type t() :: %__MODULE__{
          effect: :allow | :ask | :deny,
          message: String.t() | nil,
          rule: String.t() | nil,
          policy: String.t() | nil,
          cause: :rule | :gate | :no_rule | :judge | :budget
        }

  @doc """
  Picks the strictest decision. A deny beats an ask, and an ask beats an allow. Between two the
  same, one a rule or judge named beats one a default made. No decisions allow.
  """
  @spec strictest([t()]) :: t()
  def strictest([]), do: %__MODULE__{effect: :allow, cause: :no_rule}
  def strictest(decisions), do: Enum.min_by(decisions, &rank/1)

  @doc "Ranks an effect from strictest, `:deny`, to least strict, `:allow`."
  @spec strictness(:allow | :ask | :deny) :: 0..2
  def strictness(:deny), do: 0
  def strictness(:ask), do: 1
  def strictness(:allow), do: 2

  @doc false
  @spec outcome(t()) :: WardrikPolicy.decision()
  def outcome(%__MODULE__{effect: :allow}), do: :allow
  def outcome(%__MODULE__{effect: effect, message: message}), do: {effect, message}

  defp rank(decision), do: {strictness(decision.effect), decision.cause == :no_rule}
end
