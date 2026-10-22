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

    @spec explain(Context.t(), [WardrikPolicy.t()]) :: Decision.t()
    def explain(context, policies) do
      spent = spent(context)

      policies
      |> budgeted()
      |> Enum.map(fn {key, policy} -> decision(policy, spent[key]) end)
      |> Enum.reject(&is_nil/1)
      |> Decision.strictest()
    end

    @spec grant(Context.t(), [WardrikPolicy.t()]) :: Context.t()
    def grant(context, policies), do: update(context, policies, &Budget.grant/2)

    @spec record(Context.t(), [WardrikPolicy.t()]) :: Context.t()
    def record(context, policies) do
      gained = gained(context)

      context
      |> update(policies, &spend(&1, &2, gained))
      |> Context.put_private(__MODULE__, %{trace: trace(context), counted: context.measurements})
    end

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

    defp gained(context) do
      counted = counted(Context.get_private(context, __MODULE__), trace(context))

      context.measurements
      |> Map.new(fn {key, amount} -> {key, amount - Map.get(counted, key, 0)} end)
      |> Map.reject(fn {_key, amount} -> amount == 0 end)
    end

    defp counted(%{trace: trace, counted: counted}, trace), do: counted
    defp counted(_counted, _trace), do: %{}

    defp trace(%Context{span: nil}), do: nil
    defp trace(%Context{span: span}), do: span.trace

    defp spend(_budget, spent, gained) when map_size(gained) == 0, do: spent

    defp spend(budget, spent, gained) do
      cost = cost(budget, gained)
      tokens = Map.get(gained, :input_tokens, 0) + Map.get(gained, :output_tokens, 0)

      %{
        spent
        | usd: spent.usd + (cost || 0),
          tokens: spent.tokens + tokens,
          unpriced: spent.unpriced or cost == nil
      }
    end

    defp cost(budget, %{unpriced_calls: _calls} = gained),
      do: Budget.cost(budget, Map.delete(gained, :usd))

    defp cost(_budget, gained), do: Map.get(gained, :usd, 0)

    defp update(context, policies, fun) do
      spent =
        Enum.reduce(budgeted(policies), spent(context), fn {key, policy}, spent ->
          Map.update!(spent, key, &fun.(policy.budget, &1))
        end)

      Context.put_private(context, Budget, spent)
    end
  end
end
