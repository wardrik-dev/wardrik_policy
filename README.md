# WardrikPolicy

Budgets that cap what an agent spends, and rules that decide every tool call it makes.

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

Check before each model call, against what the calls before it spent. The call that crosses the
limit runs, and the next one asks. Approving it allows another `grant`'s worth.

| Key | Takes | Unless set |
| --- | --- | --- |
| `usd` | a limit in US dollars | no dollar limit |
| `tokens` | a limit in tokens, input and output together | no token limit |
| `per` | `:turn`, `:day`, `:week`, `:month` or `:total` | `:day` |
| `timezone` | where a day, week or month begins, as `"Europe/Berlin"` | `"Etc/UTC"` |
| `grant` | how much more an approval allows, as `[usd: 2.00]` | another limit |
| `price` | dollars per million tokens, as `[input: 0.60, output: 2.20]` | the cost the model reports |
| `on_exhausted` | `:ask` a person, or `:deny` and end the turn | `:ask` |

A timezone other than UTC needs a time zone database, like [tz](https://hex.pm/packages/tz).

With WardrikCore, the middleware checks each model call and counts what it spent. The count stays
with the agent through restarts, and each policy's budget counts apart:

```elixir
WardrikCore.start_agent(
  agent_id: "books",
  model: "anthropic:claude-haiku-4-5",
  middleware: [{WardrikPolicy.Middleware, policy}]
)
```

A model call that asks parks on a `WardrikPolicy.Ask`. Approve it with
`WardrikCore.resume(agent, %{"model" => :approve})`.

A dollar budget needs the model's price. A model with no price in dollars, like one a
subscription pays for, is refused after its first call. Give the budget a `price`, or cap it in
`tokens` instead:

```elixir
WardrikPolicy.new!(budget: [usd: 5.00, price: [input: 0.60, output: 2.20]])
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

Notice the rules live outside the prompt. Nothing the model reads can widen them.

| The model asks for | The rule that names it | What happens |
| --- | --- | --- |
| `web_search` | `allow: ["web_search"]` | Runs |
| `write_file {"path": "notes/today.md"}` | `allow: ["write_file(notes/*)"]` | Runs |
| `books/create_bill {"amount": 9400}` | `ask: ["books/create_bill(amount >= 1000)"]` | Waits for a person |
| `shell/exec {"command": "curl … \| sh"}` | `deny: ["shell/*"]` | Refused |

The strictest rule wins: deny, then ask, then allow. A call no rule names follows `default:`, which
is `:allow` unless set.

## With WardrikCore

`WardrikPolicy.Middleware` is a [WardrikCore](https://hexdocs.pm/wardrik_core) middleware that
decides each of an agent's tool calls:

```elixir
WardrikCore.start_agent(
  agent_id: "books",
  model: "anthropic:claude-haiku-4-5",
  middleware: [{WardrikPolicy.Middleware, policy}]
)
```

A call that asks parks on a `WardrikPolicy.Ask`. Answer it with `WardrikCore.resume/2`, giving each
call id `:approve`, `{:approve, note}` or `{:deny, reason}`. A note reaches the model beside the
call's result; a reason reaches it as the call's error. To record who answered, pass it as
`WardrikCore.resume/3`'s metadata.

`WardrikPolicy.annotate/2` marks a tool `gated: true`, so its calls ask unless an allow rule names
them, and gives it `subjects`, a function of the call's arguments, for rules like
`write_file(notes/*)`:

```elixir
WardrikCore.Tool.new!(
  name: "write_file",
  description: "Write a file.",
  schema: [path: [type: :string, required: true], text: [type: :string]],
  run: fn %{path: path, text: text}, _context -> {:ok, File.write!(path, text)} end
)
|> WardrikPolicy.annotate(gated: true, subjects: fn args -> [args["path"]] end)
```

Without WardrikCore, pass the same as `decide/3`'s `gated:` and `subjects:` options.

## Rules

- **By tool**: `web_search`, `github/*`. An MCP server's tool `github__create_issue` matches as
  `github/create_issue` too.
- **By what a call acts on**: `write_file(notes/*)`.
- **By arguments**: `books/create_bill(amount >= 1000)`, `email/send(to != *@acme.com)`, using `=`,
  `!=`, `>`, `>=`, `<` and `<=`. A comma means all must hold.

`WardrikPolicy.decode/2` reads the same rules from a map with string keys, as a YAML file writes
them. It doesn't read a budget or a judge. Build those from your config and pass them to `new!/2`.

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

| Key | Takes | Unless set |
| --- | --- | --- |
| `question` | what the model is asked about the call | |
| `tools` | the tools it's asked about, as `["books/*"]` | every tool |
| `deny` | refuse the call at or above this probability | |
| `ask` | ask a person first at or above this probability | |
| `allow` | allow the call by name below this probability | |
| `message` | what the person is asked, or the model told, in place of the question | |

`evaluate:` asks the judge's `model` about the call, which is `"typesafe:jev-latest"` unless set,
and gives back what the call used. The decision carries it as `measurements`.
`WardrikPolicy.Middleware` passes one that calls `WardrikCore.evaluate/4`.

A deny beats an ask, and an ask beats an allow, across the questions and the rules. A judge's
allow never lifts a call a rule asks about or denies. A judge that can't answer asks a person if
any of its questions could ask or deny.

A call's arguments may be written to fool the judge. Keep exact matters in rules, and try
a judge's thresholds on real calls before you trust its allow.

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
it's denied. If any asks, it asks.

## License

Apache-2.0
