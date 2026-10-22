# WardrikPolicy

Rules that decide every tool call an agent makes: run it, ask a person first, or refuse it.

## Install

```elixir
def deps do
  [
    {:wardrik_policy, "~> 0.1"}
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
call's result; a reason reaches it as the call's error.

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

`WardrikPolicy.decode/1` reads the same rules from a map with string keys, as a YAML file writes
them.

## License

Apache-2.0
