# Changelog

## 0.1.0-rc.1 (2026-10-30)

- Rules that allow, ask about or deny each tool call, by tool, by the resources a call acts on, and
  by its arguments. The strictest rule wins, across several policies too.
- A `default` that can turn on a tool's annotations, like `[read_only: :allow, else: :ask]`.
- Policies built in Elixir with `new!/2`, read from YAML or JSON with `decode/2`, and written back
  with `to_json/1`.
- Budgets in dollars, tokens or both, per turn, day, week, month or for good, in any time zone.
- Judges that ask a model yes-or-no questions about a call, and decide by the probability of yes.
- Gated calls wait for a person once the run has read content from outside, unless `allow_after`
  allows them after that label.
- `WardrikPolicy.Middleware`, which holds a WardrikCore agent to its policies, parks calls that ask,
  and reports every decision as a telemetry event and on its step's span.
- The protocol's `wardrik.tool_call.denied` and `wardrik.interrupt.resolved` events, and asks that
  name their `interrupt`, `message` and the run's labels.
