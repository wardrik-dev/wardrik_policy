# WardrikPolicy

Rules, judges and budgets that decide what an agent may do and spend.

## Install

```elixir
def deps do
  [
    {:wardrik_policy, "~> 0.1.0-rc.1"}
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

The rules live outside the prompt, so nothing the model reads can widen them.

| The model asks for | The rule that names it | What happens |
| --- | --- | --- |
| `web_search` | `allow: ["web_search"]` | Runs |
| `write_file {"path": "notes/today.md"}` | `allow: ["write_file(notes/*)"]` | Runs |
| `books/create_bill {"amount": 9400}` | `ask: ["books/create_bill(amount >= 1000)"]` | Waits for a person |
| `shell/exec {"command": "curl … \| sh"}` | `deny: ["shell/*"]` | Refused |

The strictest rule wins: deny, then ask, then allow. A call no rule names follows `default:`, which
is `:allow` unless set.

To see which rule decided, call `WardrikPolicy.explain/3`. It returns a `WardrikPolicy.Decision`.

## Rules

```elixir
"web_search"                         # a tool
"github/*"                           # every tool from the github MCP server
"write_file(notes/*)"                # what the call acts on
"books/create_bill(amount >= 1000)"  # an argument
"email/send(to != *@acme.com)"       # a comma means all conditions must hold
```

- An MCP tool named `github__create_issue` also matches as `github/create_issue`.
- Pass what a call acts on as `decide/3`'s `resources:`.
- Conditions use `=`, `!=`, `>`, `>=`, `<` and `<=`.

## Decide what no rule names

A tool describes itself with annotations, like `read_only: true`. The `default` can depend on them:

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

- `github/create_issue` runs, because a rule names it.
- A tool marked destructive is refused.
- When a tool has several annotations, the strictest wins.
- `else` covers a tool with none of them. It is `:allow` unless set.

A default applies to its own policy only. An agent's own allow can't lift its org's `else: :ask`.

## Policy files

`WardrikPolicy.decode/2` reads a policy from a map with string keys, such as one parsed from YAML.
It reads `budget` and `judge` too.

```yaml
allow: [web_search]
deny: ["email/send(to != *@acme.com)"]
default: ask
budget:
  usd: 5.00
  per: day
```

## After content from outside

A run that has read content from outside, such as a web page or an issue a stranger filed, may have
been told what to call. Once a run has the `"outside"` label, a call to a gated tool asks a person,
even if a rule allows it. See `WardrikCore.Context.labels/1`.

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
- `allow_after` keeps a call allowed after that label. Use it for tools a stranger can't misuse.
- An ask or deny still wins over `allow_after`.
- Any label `allow_after` names holds gated calls the same way `"outside"` does.
- A judge's allow is ignored once the run has read content from outside.

## Judge a call

Some decisions depend on what a call means, not its name. A judge asks a model yes-or-no
questions about each call, and decides by the probability of yes:

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

A judge takes a `model`, `"typesafe:jev-latest"` unless set, and its `questions`. Each question
takes:

| Key | Takes | Unless set |
| --- | --- | --- |
| `question` | what the model is asked about the call | required |
| `tools` | tool names it applies to, as `["books/*"]`, without arguments | every tool |
| `deny` | refuse the call at or above this probability | |
| `ask` | ask a person at or above this probability | |
| `allow` | allow the call below this probability | |
| `message` | the prompt or refusal to show in place of the question | |

A question needs at least one of `deny`, `ask` and `allow`, each from 0 to 1.

`evaluate:` is the function that asks the model. It returns each question's probability of yes and
what the request used. The decision carries that as `measurements`.

- A deny beats an ask, and an ask beats an allow, across questions and rules.
- A judge's allow never overrides a rule's ask or deny.
- If the model can't answer, the call asks a person, as long as some question could ask or deny.

The call's arguments may be written to fool the judge. Keep exact checks in rules, and test the
thresholds on real calls before trusting the judge's allow.

## Cap what an agent spends

```elixir
policy = WardrikPolicy.new!(budget: [usd: 5.00, per: :day])

WardrikPolicy.Budget.check(policy.budget, %{usd: 5.02})
#=> {:ask, "This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more."}
```

Check the budget before each model call, with what the earlier calls spent. The call that crosses
the limit still runs. The next one asks. Approving allows another `grant`'s worth.

| Key | Takes | Unless set |
| --- | --- | --- |
| `usd` | a limit in US dollars | no dollar limit |
| `tokens` | a limit in tokens, input and output together | no token limit |
| `per` | `:turn`, `:day`, `:week`, `:month` or `:total` | `:day` |
| `timezone` | where a day, week or month begins, as `"Europe/Berlin"` | `"Etc/UTC"` |
| `grant` | how much more an approval allows, as `[usd: 2.00]` | another limit |
| `price` | dollars per million tokens, as `[input: 0.60, output: 2.20]` | the cost the model reports |
| `on_exhausted` | `:ask` a person, or `:deny` | `:ask` |

Weeks begin on Monday.

`WardrikPolicy.Middleware` keeps track of spending for you. To do it yourself:

1. Reset what was spent when `WardrikPolicy.Budget.period/2` returns a new period.
2. Pass it through `WardrikPolicy.Budget.grant/2` when a person approves.

## Several policies

Pass a list to `decide/3` to hold an agent to its org's policy and its own. The strictest decision
wins, so an agent's own policy can add caution but never remove it:

```yaml
# acme.yaml, the org's
deny: [shell/*]
```

```yaml
# books.yaml, the agent's
allow: [shell/*, books/*]
```

`shell/exec` is refused, even though the agent's policy allows it. Each policy's budget is counted
separately.

## With WardrikCore

`WardrikPolicy.Middleware` is a [WardrikCore](https://hexdocs.pm/wardrik_core) middleware. It
checks each model call against the budgets, and decides each tool call by the rules and judges:

```elixir
WardrikCore.start_agent(
  agent_id: "books",
  model: "anthropic:claude-haiku-4-5",
  middleware: [{WardrikPolicy.Middleware, policy}]
)
```

- What the agent spent survives restarts.
- A judge asks its model with `WardrikCore.evaluate/4`. That cost counts against the budget too.
- A dollar budget needs the model's price. If the model reports no dollar cost, as with a
  subscription, model calls are refused after the first one. Set the budget's `price`, or cap
  `tokens` instead.

A call that asks parks on a `WardrikPolicy.Ask`. Answer it with `WardrikCore.resume/3`, keyed by
the tool call's id, or `"model"` for a model call:

```elixir
WardrikCore.resume(agent, %{"call_123" => :approve}, %{by: "maria"})
WardrikCore.resume(agent, %{"call_123" => {:approve, "Checked with finance."}})
WardrikCore.resume(agent, %{"model" => {:deny, "Over budget for today."}})
```

A note reaches the model beside the call's result. A reason reaches it as the call's error. The
metadata records who answered.

The middleware reads each tool's annotations from `WardrikCore.Tool`. The `resources` annotation
returns what a call acts on, from its arguments:

```elixir
WardrikCore.Tool.new!(
  name: "write_file",
  description: "Write a file.",
  schema: [path: [type: :string, required: true], text: [type: :string]],
  run: fn %{path: path, text: text}, _context -> {:ok, File.write!(path, text)} end,
  annotations: [resources: fn args -> [args["path"]] end]
)
```

Every decision and answer is a telemetry event, and each decision is set on its step's span. That
is the record of what the agent was allowed to do, and who said so. See `WardrikPolicy.Middleware`.

## License

Apache-2.0
