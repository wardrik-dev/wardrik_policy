# WardrikPolicy

Budgets that cap what an agent spends, and rules and judges that decide every tool call it makes.

## Install

```elixir
def deps do
  [
    {:wardrik_policy, "~> 0.1"}
  ]
end
```

## Cap what an agent spends

```elixir
policy = WardrikPolicy.new!(budget: [usd: 5.00, per: :day])

WardrikPolicy.Budget.check(policy.budget, %{usd: 5.02})
#=> {:ask, "This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more."}
```

Check the budget before each model call, against what the calls before it spent. The call that
crosses the limit runs, and the next one asks. Approving it allows another `grant`'s worth.

| Key | Takes | Unless set |
| --- | --- | --- |
| `usd` | a limit in US dollars | no dollar limit |
| `tokens` | a limit in tokens, input and output together | no token limit |
| `per` | `:turn`, `:day`, `:week`, `:month` or `:total` | `:day` |
| `timezone` | where a day, week or month begins, as `"Europe/Berlin"` | `"Etc/UTC"` |
| `grant` | how much more an approval allows, as `[usd: 2.00]` | another limit |
| `price` | dollars per million tokens, as `[input: 0.60, output: 2.20]` | the cost the model reports |
| `on_exhausted` | `:ask` a person, or `:deny` | `:ask` |

Days, weeks and months begin at midnight UTC, and weeks begin on Monday. To count them where your
people are, give the budget a `timezone`:

```elixir
WardrikPolicy.new!(budget: [usd: 5.00, per: :day, timezone: "Europe/Berlin"])
```

Keep what was spent yourself, or let `WardrikPolicy.Middleware` keep it for you. Start it over when
`WardrikPolicy.Budget.period/2` changes, and pass it through `WardrikPolicy.Budget.grant/2` when a
person approves.

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

Notice the rules live outside the prompt. Nothing the model reads can widen them.

| The model asks for | The rule that names it | What happens |
| --- | --- | --- |
| `web_search` | `allow: ["web_search"]` | Runs |
| `write_file {"path": "notes/today.md"}` | `allow: ["write_file(notes/*)"]` | Runs |
| `books/create_bill {"amount": 9400}` | `ask: ["books/create_bill(amount >= 1000)"]` | Waits for a person |
| `shell/exec {"command": "curl … \| sh"}` | `deny: ["shell/*"]` | Refused |

The strictest rule wins: deny, then ask, then allow. A call no rule names follows `default:`, which
is `:allow` unless set.

## Rules

- **By tool**: `web_search`, `github/*`. An MCP server's tool `github__create_issue` matches as
  `github/create_issue` too.
- **By what a call acts on**: `write_file(notes/*)`. Pass what it acts on as `decide/3`'s
  `resources:`.
- **By arguments**: `books/create_bill(amount >= 1000)`, `email/send(to != *@acme.com)`, using `=`,
  `!=`, `>`, `>=`, `<` and `<=`. A comma means all must hold.

## Decide what no rule names

A tool says what it is with annotations, like `read_only: true`. A call no rule names follows the
`default`, and the default can turn on those annotations:

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

`github/create_issue` runs, because a rule names it. A tool that isn't marked read-only asks, and
one marked destructive is refused. When a tool has several annotations, the strictest wins. `else`
covers a tool with none of them, and allows unless set.

A default speaks for its own policy only. An agent's own allow can't lift its org's `else: ask`.

`WardrikPolicy.decode/2` reads the same policy from a map with string keys, as a YAML file writes
it, its `budget` and `judge` included.

## After content from outside

A run carries labels for what it has read; see `WardrikCore.Context.labels/1`. Once it has read
content from outside, such as a web page or an issue a stranger filed, a gated tool's call waits for
a person however the rules allow it, since what it read may be what asked for the call:

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

A tool is gated when its annotations say `gated: true`. `allow_after` allows a call by name as
`allow` does, and holds after its label too, for tools a stranger can't misuse. An ask or deny still
wins over it. A label `allow_after` names holds gated calls the way `outside` does, and one no rule
names holds nothing. A judge's allow holds only while the run has read nothing from outside.

## Judge a call

Some decisions turn on what a call means, not its name. A judge asks a model yes-or-no questions
about each call, and decides by the probability of yes:

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
| `question` | what the model is asked about the call | |
| `tools` | the tools it's asked about, as `["books/*"]` | every tool |
| `deny` | refuse the call at or above this probability | |
| `ask` | ask a person first at or above this probability | |
| `allow` | allow the call by name below this probability | |
| `message` | what the person is asked, or the model told, in place of the question | |

A question needs at least one of `deny`, `ask` and `allow`, each a probability from 0 to 1, or it
decides nothing and the policy is refused. Its `tools` are names alone, without arguments.

`evaluate:` is the function that asks the model. It gives back each question's probability of yes,
and what the call used, which the decision carries as `measurements`.

A deny beats an ask, and an ask beats an allow, across the questions and the rules. A judge's
allow never lifts a call a rule asks about or denies. A judge that can't answer asks a person if
any of its questions could ask or deny.

A call's arguments may be written to fool the judge. Keep exact matters in rules, and try a judge's
thresholds on real calls before you trust its allow.

## Several policies

Hold an agent to an org's policy and its own by giving `decide/3` a list. The strictest decision
wins, so an agent's own policy can add caution but never remove it:

```yaml
# acme.yaml, the org's
deny: [shell/*]
```

```yaml
# books.yaml, the agent's
allow: [shell/*, books/*]
```

`shell/exec` is refused here, even though the agent's policy allows it. If any policy denies a call,
it's denied. If any asks, it asks. Each policy's budget counts apart.

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

What the agent spent stays with it through restarts. A judge asks its model with
`WardrikCore.evaluate/4`, and what that costs counts against the budget too.

A call that asks parks on a `WardrikPolicy.Ask`. Answer it with `WardrikCore.resume/2`, giving each
tool call's id, or `"model"` for a model call, `:approve`, `{:approve, note}` or `{:deny, reason}`.
The ask carries the run's labels, and so does every decision event. A note reaches the model beside the call's result. A reason reaches it as the call's error. To
record who answered, pass it as `WardrikCore.resume/3`'s metadata.

A dollar budget needs the model's price. A model with no price in dollars, like one a subscription
pays for, is refused after its first call. Give the budget a `price`, or cap it in `tokens` instead.

The middleware reads each tool's annotations from `WardrikCore.Tool`. A tool's `resources`
annotation says what a call acts on, as a function of its arguments:

```elixir
WardrikCore.Tool.new!(
  name: "write_file",
  description: "Write a file.",
  schema: [path: [type: :string, required: true], text: [type: :string]],
  run: fn %{path: path, text: text}, _context -> {:ok, File.write!(path, text)} end,
  annotations: [resources: fn args -> [args["path"]] end]
)
```

Every decision and every answer is a telemetry event, and each decision is set on its step's span.
That's the record of what the agent was allowed to do, and who said so; see
`WardrikPolicy.Middleware`.

## License

Apache-2.0
