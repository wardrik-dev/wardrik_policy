defmodule WardrikPolicy.Decision do
  @moduledoc """
  What a policy decided about a call, and why. Returned by `WardrikPolicy.explain/3`.

    * `:effect` - `:allow`, `:ask` or `:deny`.
    * `:message` - the prompt or refusal. `nil` for an allow.
    * `:rule` - the rule that decided, when `:cause` is `:rule` or `:label`.
    * `:policy` - the name of the policy that decided, if it has one.
    * `:cause` - what decided. See below.
    * `:measurements` - what a judge's model call used.

  The `:cause` is one of:

    * `:rule` - a rule named the call.
    * `:no_rule` - no rule covered the whole call, so `default` decided.
    * `:judge` - the policy's judge decided.
    * `:budget` - a model call reached the policy's budget.
    * `:label` - a rule allowed a gated call, but the run had read labelled content.
  """

  @enforce_keys [:effect, :cause]
  defstruct [:effect, :message, :rule, :policy, :cause, measurements: %{}]

  @type t() :: %__MODULE__{
          effect: :allow | :ask | :deny,
          message: String.t() | nil,
          rule: String.t() | nil,
          policy: String.t() | nil,
          cause: :rule | :no_rule | :judge | :budget | :label,
          measurements: %{optional(term()) => number()}
        }

  @doc """
  Returns the strictest decision. A deny beats an ask, and an ask beats an allow.

  On a tie, a decision from a rule or judge beats one from a default. An empty list allows. The
  result carries the summed measurements of all of them.
  """
  @spec strictest([t()]) :: t()
  def strictest([]), do: %__MODULE__{effect: :allow, cause: :no_rule}

  def strictest(decisions),
    do: %{Enum.min_by(decisions, &rank/1) | measurements: measured(decisions)}

  @doc "Ranks an effect: `0` for `:deny`, `1` for `:ask`, `2` for `:allow`."
  @spec strictness(:allow | :ask | :deny) :: 0..2
  def strictness(:deny), do: 0
  def strictness(:ask), do: 1
  def strictness(:allow), do: 2

  @doc false
  @spec outcome(t()) :: WardrikPolicy.decision()
  def outcome(%__MODULE__{effect: :allow}), do: :allow
  def outcome(%__MODULE__{effect: effect, message: message}), do: {effect, message}

  defp measured(decisions) do
    Enum.reduce(decisions, %{}, fn decision, measured ->
      Map.merge(measured, decision.measurements, fn _key, one, other -> one + other end)
    end)
  end

  defp rank(decision), do: {strictness(decision.effect), decision.cause == :no_rule}
end
