if Code.ensure_loaded?(WardrikCore.Context) do
  defmodule WardrikPolicy.Spending do
    @moduledoc false

    alias WardrikCore.Context
    alias WardrikPolicy.Budget
    alias WardrikPolicy.Decision

    @spec start(Context.t(), [WardrikPolicy.t()]) :: Context.t()
    def start(context, policies) do
      spent = spent(context)

      current =
        Map.new(budgeted(policies), fn {key, policy} ->
          {key, current(spent[key], period(policy.budget, context))}
        end)

      Context.put_private(context, Budget, current)
    end

    @spec explain(Context.t(), [WardrikPolicy.t()]) :: Decision.t() | nil
    def explain(context, policies) do
      spent = spent(context)

      policies
      |> budgeted()
      |> Enum.map(fn {key, policy} -> decision(policy, spent[key]) end)
      |> Enum.reject(&is_nil/1)
      |> strictest()
    end

    @spec grant(Context.t(), [WardrikPolicy.t()]) :: Context.t()
    def grant(context, policies), do: update(context, policies, &Budget.grant/2)

    @spec record(Context.t(), [WardrikPolicy.t()]) :: Context.t()
    def record(context, policies),
      do: update(context, policies, &spend(&1, &2, context.usage))

    defp budgeted(policies) do
      for {%WardrikPolicy{budget: %Budget{}} = policy, index} <- Enum.with_index(policies),
          do: {policy.name || index, policy}
    end

    defp spent(context), do: Context.get_private(context, Budget, %{})

    defp period(%Budget{per: :turn}, context), do: {:turn, asked(context.messages)}
    defp period(budget, _context), do: Budget.period(budget, DateTime.utc_now())

    defp asked(messages), do: Enum.count(messages, &(&1.role == :user))

    defp current(%{period: period} = spent, period), do: spent

    defp current(_spent, period),
      do: %{period: period, usd: 0, tokens: 0, granted: %{}, unpriced: false}

    defp decision(%WardrikPolicy{budget: %Budget{usd: usd}} = policy, %{unpriced: true})
         when usd != nil do
      %Decision{
        effect: :deny,
        message: "This model has no price in dollars, so the budget can't hold it.",
        policy: policy.name,
        cause: :budget
      }
    end

    defp decision(policy, spent), do: exhausted(policy, Budget.check(policy.budget, spent))

    defp exhausted(_policy, :allow), do: nil

    defp exhausted(policy, {effect, message}),
      do: %Decision{effect: effect, message: message, policy: policy.name, cause: :budget}

    defp strictest([]), do: nil

    defp strictest(decisions),
      do: Enum.find(decisions, List.first(decisions), &(&1.effect == :deny))

    defp spend(budget, spent, usage) do
      cost = Budget.cost(budget, usage)

      %{
        spent
        | usd: spent.usd + (cost || 0),
          tokens: spent.tokens + usage.input_tokens + usage.output_tokens,
          unpriced: cost == nil
      }
    end

    defp update(context, policies, fun) do
      spent =
        Enum.reduce(budgeted(policies), spent(context), fn {key, policy}, spent ->
          Map.update!(spent, key, &fun.(policy.budget, &1))
        end)

      Context.put_private(context, Budget, spent)
    end
  end
end
