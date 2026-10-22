defmodule WardrikPolicy.BudgetTest do
  use ExUnit.Case, async: true

  alias WardrikPolicy.Budget

  doctest Budget

  describe "check/2" do
    test "denies instead of asking when on_exhausted is deny" do
      budget = %Budget{usd: 5, per: :month, on_exhausted: :deny}

      assert {:deny, "This agent has spent $5.00 of $5.00 this month."} =
               Budget.check(budget, %{usd: 5})
    end

    test "says the period it counts" do
      for {per, said} <- [turn: " this turn", week: " this week", total: ""] do
        assert {:ask, message} = Budget.check(%Budget{tokens: 1000, per: per}, %{tokens: 1000})
        assert message =~ "1,000 of 1,000 tokens#{said}. Approve"
      end
    end

    test "nothing spent is within any budget" do
      assert :allow = Budget.check(%Budget{usd: 1, tokens: 10}, %{})
    end
  end

  describe "grant/2" do
    test "allows a grant's worth more of each limit reached, from what was spent" do
      budget = %Budget{usd: 5, tokens: 1000}
      spent = Budget.grant(budget, %{usd: 7.5, tokens: 10})

      assert %{granted: %{usd: 7.5}} = spent
      assert :allow = Budget.check(budget, spent)

      assert {:ask, "This agent has spent $12.50 of $12.50 today." <> _rest} =
               Budget.check(budget, %{spent | usd: 12.5})
    end
  end

  describe "cost/2" do
    test "takes the cost a call reports over the budget's price" do
      budget = %Budget{usd: 5, price: [input: 1.0, output: 1.0]}

      assert 0.25 = Budget.cost(budget, %{usd: 0.25, input_tokens: 10, output_tokens: 10})
      assert nil == Budget.cost(%Budget{usd: 5}, %{usd: nil, input_tokens: 10})
    end
  end

  describe "period/2" do
    test "names the day, week or month a moment falls in" do
      now = ~U[2026-10-21 23:30:00Z]
      period = fn per -> Budget.period(%Budget{usd: 1, per: per}, now) end

      assert {:day, ~D[2026-10-21]} = period.(:day)
      assert {:week, ~D[2026-10-19]} = period.(:week)
      assert {:month, ~D[2026-10-01]} = period.(:month)
      assert :total = period.(:total)
      assert :turn = period.(:turn)
    end
  end
end
