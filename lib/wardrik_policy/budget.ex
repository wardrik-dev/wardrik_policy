defmodule WardrikPolicy.Budget do
  @moduledoc """
  A budget caps what an agent spends on model calls, in dollars, tokens or both.

      iex> policy = WardrikPolicy.new!(budget: [usd: 5.00, per: :day])
      iex> WardrikPolicy.Budget.check(policy.budget, %{usd: 4.10})
      :allow
      iex> WardrikPolicy.Budget.check(policy.budget, %{usd: 5.02})
      {:ask, "This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more."}

  Check before each call, against what the calls before it spent. The call that crosses the limit
  runs, and the next one asks. Approving it allows another `grant`'s worth:

      iex> policy = WardrikPolicy.new!(budget: [tokens: 200_000, grant: [tokens: 50_000]])
      iex> spent = WardrikPolicy.Budget.grant(policy.budget, %{tokens: 201_000})
      iex> WardrikPolicy.Budget.check(policy.budget, spent)
      :allow
      iex> WardrikPolicy.Budget.check(policy.budget, %{spent | tokens: 251_000})
      {:ask, "This agent has used 251,000 of 251,000 tokens today. Approve to allow 50,000 more."}

  A call that reports no cost is priced at the budget's `price`, in dollars per million tokens:

      iex> policy = WardrikPolicy.new!(budget: [usd: 5.00, price: [input: 0.60, output: 2.20]])
      iex> WardrikPolicy.Budget.cost(policy.budget, %{input_tokens: 10_000, output_tokens: 2_000})
      0.0104

  What was spent is a map of `usd`, `tokens` and what approvals `granted`, each zero unless set.
  Start it over when `period/2` changes.
  """

  alias WardrikPolicy.Read

  defstruct usd: nil,
            tokens: nil,
            per: :day,
            timezone: "Etc/UTC",
            grant: [],
            price: nil,
            on_exhausted: :ask

  @typedoc """
  A budget sets `usd`, `tokens` or both.

    * `usd` - a limit in US dollars.
    * `tokens` - a limit in tokens, input and output together.
    * `per` - how long the limits last: `:turn`, `:day`, `:week`, `:month` or `:total`.
    * `timezone` - where a day, week or month begins, as `"Europe/Berlin"`.
    * `grant` - how much more an approval allows, as `[usd: 2.00]`. Another limit's worth unless set.
    * `price` - dollars per million tokens, as `[input: 0.60, output: 2.20]`, for a call that
      reports no cost.
    * `on_exhausted` - `:ask` a person, or `:deny` and end the turn.
  """
  @type t() :: %__MODULE__{
          usd: number() | nil,
          tokens: pos_integer() | nil,
          per: :turn | :day | :week | :month | :total,
          timezone: String.t(),
          grant: keyword(number()),
          price: [input: number(), output: number()] | nil,
          on_exhausted: :ask | :deny
        }
  @type spent() :: %{
          optional(:usd) => number(),
          optional(:tokens) => non_neg_integer(),
          optional(:granted) => %{optional(:usd) => number(), optional(:tokens) => integer()}
        }
  @type period() :: :turn | :total | {:day | :week | :month, Date.t()}

  @kinds [:usd, :tokens]
  @fields ~w(usd tokens per timezone grant price on_exhausted)
  @periods %{
    "turn" => :turn,
    "day" => :day,
    "week" => :week,
    "month" => :month,
    "total" => :total
  }
  @exhausted %{"ask" => :ask, "deny" => :deny}
  @amounts %{"usd" => :usd, "tokens" => :tokens}
  @prices %{"input" => :input, "output" => :output}

  @doc "Reads a budget from a map with string keys, as a YAML file writes it."
  @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
  def decode(fields) when is_map(fields) do
    with :ok <- Read.known(fields, @fields, "a budget"),
         {:ok, per} <- Read.choice(fields, "per", @periods, :day),
         {:ok, on_exhausted} <- Read.choice(fields, "on_exhausted", @exhausted, :ask),
         {:ok, grant} <- Read.keywords(fields["grant"], @amounts, "grant"),
         {:ok, price} <- Read.keywords(fields["price"], @prices, "price") do
      {:ok,
       %__MODULE__{
         usd: fields["usd"],
         tokens: fields["tokens"],
         per: per,
         timezone: Map.get(fields, "timezone", "Etc/UTC"),
         grant: grant || [],
         price: price,
         on_exhausted: on_exhausted
       }}
    end
  end

  def decode(_fields), do: {:error, "a budget is a map of #{Enum.join(@fields, ", ")}"}

  @doc """
  Checks what was spent against the budget. Returns `:allow`, `{:ask, prompt}` or
  `{:deny, message}`, as `on_exhausted` says.
  """
  @spec check(t(), spent()) :: WardrikPolicy.decision()
  def check(%__MODULE__{} = budget, spent) do
    case Enum.find(@kinds, &exhausted?(budget, spent, &1)) do
      nil -> :allow
      kind -> {budget.on_exhausted, message(budget, spent, kind)}
    end
  end

  @doc """
  What a call cost in dollars. That's its own `usd` when it reports one, or its tokens at the
  budget's `price`. Returns `nil` when neither is known.
  """
  @spec cost(t(), map()) :: number() | nil
  def cost(_budget, %{usd: usd}) when is_number(usd), do: usd
  def cost(%__MODULE__{price: nil}, _usage), do: nil

  def cost(%__MODULE__{price: price}, usage) do
    input = Map.get(usage, :input_tokens, 0) * price[:input]
    output = Map.get(usage, :output_tokens, 0) * price[:output]
    (input + output) / 1_000_000
  end

  @doc "Allows another `grant`'s worth on top of what was spent, for each limit it has reached."
  @spec grant(t(), spent()) :: spent()
  def grant(%__MODULE__{} = budget, spent) do
    granted =
      @kinds
      |> Enum.filter(&exhausted?(budget, spent, &1))
      |> Enum.reduce(Map.get(spent, :granted, %{}), fn kind, granted ->
        Map.put(granted, kind, used(spent, kind) - Map.fetch!(budget, kind) + more(budget, kind))
      end)

    Map.put(spent, :granted, granted)
  end

  @doc """
  Names the period `now` falls in. Start what was spent over when it changes.

  A `:turn` budget's period is always `:turn`, so start it over at each turn yourself.
  """
  @spec period(t(), DateTime.t()) :: period()
  def period(%__MODULE__{per: :turn}, _now), do: :turn
  def period(%__MODULE__{per: :total}, _now), do: :total

  def period(%__MODULE__{per: per, timezone: timezone}, now) do
    case DateTime.shift_zone(now, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> {per, starts(per, DateTime.to_date(local))}
      {:error, _reason} -> raise ArgumentError, "budget timezone #{timezone} is not a time zone"
    end
  end

  defp starts(:day, date), do: date
  defp starts(:week, date), do: Date.beginning_of_week(date)
  defp starts(:month, date), do: Date.beginning_of_month(date)

  defp exhausted?(budget, spent, kind) do
    case Map.fetch!(budget, kind) do
      nil -> false
      _limit -> used(spent, kind) >= limit(budget, spent, kind)
    end
  end

  defp used(spent, kind), do: Map.get(spent, kind, 0)

  defp limit(budget, spent, kind),
    do: Map.fetch!(budget, kind) + (spent |> Map.get(:granted, %{}) |> Map.get(kind, 0))

  defp more(budget, kind), do: budget.grant[kind] || Map.fetch!(budget, kind)

  defp message(budget, spent, kind) do
    reached = reached(kind, used(spent, kind), limit(budget, spent, kind), budget.per)

    if budget.on_exhausted == :ask,
      do: "#{reached} #{offer(kind, more(budget, kind))}",
      else: reached
  end

  defp reached(:usd, used, limit, per),
    do: "This agent has spent #{dollars(used)} of #{dollars(limit)}#{during(per)}."

  defp reached(:tokens, used, limit, per),
    do: "This agent has used #{count(used)} of #{count(limit)} tokens#{during(per)}."

  defp offer(:usd, amount), do: "Approve to allow #{dollars(amount)} more."
  defp offer(:tokens, amount), do: "Approve to allow #{count(amount)} more."

  defp during(:turn), do: " this turn"
  defp during(:day), do: " today"
  defp during(:week), do: " this week"
  defp during(:month), do: " this month"
  defp during(:total), do: ""

  defp dollars(amount), do: "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)

  defp count(amount) do
    amount
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
