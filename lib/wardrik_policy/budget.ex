defmodule WardrikPolicy.Budget do
  @moduledoc """
  Caps what an agent spends on model calls, in dollars, tokens or both.

      iex> policy = WardrikPolicy.new!(budget: [usd: 5.00, per: :day])
      iex> WardrikPolicy.Budget.check(policy.budget, %{usd: 4.10})
      :allow
      iex> WardrikPolicy.Budget.check(policy.budget, %{usd: 5.02})
      {:ask, "This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more."}

  Call `check/3` before each model call, with what the earlier calls spent. The call that crosses
  the limit still runs. The next one asks. `grant/2` records an approval and allows another
  `grant`'s worth:

      iex> policy = WardrikPolicy.new!(budget: [tokens: 200_000, grant: [tokens: 50_000]])
      iex> spent = WardrikPolicy.Budget.grant(policy.budget, %{tokens: 201_000})
      iex> WardrikPolicy.Budget.check(policy.budget, spent)
      :allow
      iex> WardrikPolicy.Budget.check(policy.budget, %{spent | tokens: 251_000})
      {:ask, "This agent has used 251,000 of 251,000 tokens today. Approve to allow 50,000 more."}

  `cost/2` prices a call that reports no cost at the budget's `price`, in dollars per million
  tokens:

      iex> policy = WardrikPolicy.new!(budget: [usd: 5.00, price: [input: 0.60, output: 2.20]])
      iex> WardrikPolicy.Budget.cost(policy.budget, %{input_tokens: 10_000, output_tokens: 2_000})
      0.0104

  What was spent is a map with `:usd`, `:tokens` and `:granted`. A missing key counts as zero.
  Reset it when `period/2` returns a new period. `WardrikPolicy.Middleware` does all of this for you.

  ## Options

    * `:usd` - the limit in US dollars. No dollar limit unless set.
    * `:tokens` - the limit in tokens, input and output together. No token limit unless set.
    * `:per` - `:turn`, `:day`, `:week`, `:month` or `:total`. `:day` unless set.
    * `:timezone` - where a day, week or month begins, as `"Europe/Berlin"`. `"Etc/UTC"` unless set.
      Weeks begin on Monday.
    * `:grant` - how much more an approval allows, as `[usd: 2.00]`. Another limit's worth unless set.
    * `:price` - dollars per million tokens, as `[input: 0.60, output: 2.20]`. Used for calls that
      report no cost.
    * `:on_exhausted` - `:ask` a person, or `:deny`. `:ask` unless set.
  """

  alias WardrikPolicy.Read

  defstruct usd: nil,
            tokens: nil,
            per: :day,
            timezone: "Etc/UTC",
            grant: [],
            price: nil,
            on_exhausted: :ask

  @typedoc "A budget. See the module docs for its fields."
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
          optional(:granted) => %{optional(:usd) => number(), optional(:tokens) => integer()},
          optional(atom()) => term()
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

  @doc "Reads a budget from a map with string keys, such as one parsed from YAML."
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

  @doc "Encodes a budget as the map `decode/1` reads. Leaves out what the budget doesn't set."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = budget) do
    Read.present(%{
      "usd" => budget.usd,
      "tokens" => budget.tokens,
      "per" => Atom.to_string(budget.per),
      "timezone" => budget.timezone,
      "grant" => Read.written(budget.grant),
      "price" => budget.price && Read.written(budget.price),
      "on_exhausted" => Atom.to_string(budget.on_exhausted)
    })
  end

  @doc """
  Checks what was spent against the budget.

  Returns `:allow` while under every limit. Otherwise returns `{:ask, prompt}` or
  `{:deny, message}`, as `:on_exhausted` says.

      iex> policy = WardrikPolicy.new!(budget: [usd: 5.00, on_exhausted: :deny])
      iex> WardrikPolicy.Budget.check(policy.budget, %{usd: 5.02}, spender: "acme's agents have")
      {:deny, "acme's agents have spent $5.02 of $5.00 today."}

  ## Options

    * `:spender` - who spent it, at the start of the message. `"This agent has"` unless set.
  """
  @spec check(t(), spent(), keyword()) :: WardrikPolicy.decision()
  def check(%__MODULE__{} = budget, spent, opts \\ []) do
    spender = Keyword.get(opts, :spender, "This agent has")

    case Enum.find(@kinds, &exhausted?(budget, spent, &1)) do
      nil -> :allow
      kind -> {budget.on_exhausted, message(budget, spent, kind, spender)}
    end
  end

  @doc """
  Returns what a call cost in dollars.

  Uses the call's own `:usd` when it has one. Otherwise prices its `:input_tokens` and
  `:output_tokens` at the budget's `:price`. Returns `nil` when the budget has no price.
  """
  @spec cost(t(), map()) :: number() | nil
  def cost(_budget, %{usd: usd}) when is_number(usd), do: usd
  def cost(%__MODULE__{price: nil}, _usage), do: nil

  def cost(%__MODULE__{price: price}, usage) do
    input = Map.get(usage, :input_tokens, 0) * price[:input]
    output = Map.get(usage, :output_tokens, 0) * price[:output]
    (input + output) / 1_000_000
  end

  @doc """
  Records an approval. Each limit already reached allows another `:grant`'s worth on top of what
  was spent.
  """
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
  Returns the period `now` falls in. Reset what was spent when it changes.

  Returns `:turn` for a `:turn` budget, so reset it at each turn yourself. Raises `ArgumentError`
  if `:timezone` isn't a time zone.
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

  defp message(budget, spent, kind, spender) do
    reached = reached(kind, spender, used(spent, kind), limit(budget, spent, kind), budget.per)

    if budget.on_exhausted == :ask,
      do: "#{reached} #{offer(kind, more(budget, kind))}",
      else: reached
  end

  defp reached(:usd, spender, used, limit, per),
    do: "#{spender} spent #{dollars(used)} of #{dollars(limit)}#{during(per)}."

  defp reached(:tokens, spender, used, limit, per),
    do: "#{spender} used #{count(used)} of #{count(limit)} tokens#{during(per)}."

  defp offer(:usd, amount), do: "Approve to allow #{dollars(amount)} more."
  defp offer(:tokens, amount), do: "Approve to allow #{count(amount)} more."

  defp during(:turn), do: " this turn"
  defp during(:day), do: " today"
  defp during(:week), do: " this week"
  defp during(:month), do: " this month"
  defp during(:total), do: ""

  defp dollars(amount) when amount >= 1 or amount <= 0,
    do: "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)

  defp dollars(amount) do
    places = max(2, 3 - floor(:math.log10(amount)))

    [whole, cents] =
      (amount / 1) |> :erlang.float_to_binary([:compact, decimals: places]) |> String.split(".")

    "$#{whole}.#{String.pad_trailing(cents, 2, "0")}"
  end

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
