# WardrikPolicy

Rules, judges and budgets that decide what an agent may do and spend.

## Install

```elixir
def deps do
  [
    {:wardrik_policy, "~> 0.1.0-rc.2"}
  ]
end
```

## Decide a call

```elixir
policy =
  WardrikPolicy.new!(
    allow: ["web_search", "write_file(notes/*)"],
    ask: %{"books/create_bill(amount >= 1000)" => "A bill this size needs a person."},
    deny: ["shell/*"]
  )

WardrikPolicy.decide(policy, "books__create_bill", arguments: %{"amount" => 9400})
#=> {:ask, "A bill this size needs a person."}
```

- The strictest rule wins: deny, then ask, then allow.
- A call no rule names follows `default:`, `:allow` by default.
- `WardrikPolicy.explain/3` says which rule decided.

## Rules

```elixir
"web_search"                         # a tool
"github/*"                           # every tool from the github MCP server
"write_file(notes/*)"                # what the call acts on, passed as resources:
"books/create_bill(amount >= 1000)"  # an argument: =, !=, >, >=, < or <=
"email/send(to != *@acme.com)"       # commas join conditions that must all hold
```

An MCP tool named `github__create_issue` also matches as `github/create_issue`.

## Defaults by annotation

```elixir
policy =
  WardrikPolicy.new!(
    allow: ["github/create_issue"],
    default: [destructive: :deny, read_only: :allow, else: :ask]
  )

WardrikPolicy.decide(policy, "github__list_issues", annotations: %{read_only: true})
#=> :allow

WardrikPolicy.decide(policy, "github__close_issue")
#=> {:ask, "github/close_issue needs your approval."}
```

- When a tool has several annotations, the strictest wins.
- `else` covers tools with none of them.

## Policy files

`WardrikPolicy.decode/2` reads a map with string keys, such as parsed YAML:

```yaml
allow: [web_search]
deny: ["email/send(to != *@acme.com)"]
default: ask
budget:
  usd: 5.00
  per: day
```

## Content from outside

Once a run has read a web page or a stranger's issue, a gated tool asks a person, even if a rule
allows it:

```elixir
policy =
  WardrikPolicy.new!(
    allow: ["linear/*"],
    allow_after: %{"outside" => ["github/add_labels"]}
  )

WardrikPolicy.decide(policy, "linear__create_issue",
  annotations: %{gated: true},
  labels: ["outside"]
)
#=> {:ask, "linear/create_issue is allowed, but this run has read content from outside, which may be what asked for it."}
```

- A tool is gated when its annotations include `gated: true`.
- `allow_after` keeps tools a stranger can't misuse allowed.

## Judge a call

A judge asks a model yes-or-no questions about a call:

```elixir
policy =
  WardrikPolicy.new!(
    judge: [
      questions: [
        [
          question: "Does this call send money outside the company?",
          tools: ["books/*"],
          ask: 0.5,
          deny: 0.9
        ]
      ]
    ]
  )

WardrikPolicy.decide(policy, "books__pay_bill",
  arguments: %{"amount" => 1200},
  evaluate: fn _model, _call, _questions -> {:ok, [0.72], %{usd: 0.0001}} end
)
#=> {:ask, "Judged 72% likely: Does this call send money outside the company?"}
```

- A judge's allow never overrides a rule's ask or deny.
- Arguments can be written to fool a judge. Keep exact checks in rules.
- See `WardrikPolicy.Judge` for every key.

## Cap spending

```elixir
policy = WardrikPolicy.new!(budget: [usd: 5.00, per: :day])

WardrikPolicy.Budget.check(policy.budget, %{usd: 5.02})
#=> {:ask, "This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more."}
```

The call that crosses the limit still runs. The next one asks. See `WardrikPolicy.Budget` for
`tokens`, `per`, `timezone`, `grant`, `price` and `on_exhausted`.

## Several policies

Pass a list to hold an agent to your app's policy and its own:

```elixir
mine = WardrikPolicy.new!(deny: ["shell/*"])
agents = WardrikPolicy.new!(allow: ["shell/*", "books/*"])

WardrikPolicy.decide([mine, agents], "shell__exec")
#=> {:deny, "shell/exec is not allowed for this agent."}
```

The strictest decision wins. Each policy counts its own budget.

## With WardrikCore

```elixir
WardrikCore.start_agent(
  agent_id: "books",
  model: "anthropic:claude-haiku-4-5",
  middleware: [{WardrikPolicy.Middleware, policy}]
)
```

A call that asks waits on a `WardrikPolicy.Ask`. Answer it by tool call ID, or `"model"` for a
budget:

```elixir
WardrikCore.resume(agent, %{"call_123" => :approve}, %{by: "user:maria"})
WardrikCore.resume(agent, %{"call_123" => {:approve, "Checked with finance."}})
WardrikCore.resume(agent, %{"model" => {:deny, "Over budget for today."}})
```

- What the agent spent survives restarts.
- A dollar budget needs a price. If the model reports no cost, set the budget's `price` or cap
  `tokens`.
- Set a tool's `resources` annotation so rules can match what it acts on.
- See `WardrikPolicy.Middleware` for its events.

## License

Apache-2.0
