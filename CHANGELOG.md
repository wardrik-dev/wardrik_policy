# Changelog

## 0.1.0 (unreleased)

- Rules that allow, ask about or deny each tool call, by tool, by the resources a call acts on, and
  by its arguments. The strictest rule wins, across several policies too.
- A `default` that can turn on a tool's annotations, like `[read_only: :allow, else: :ask]`.
- Budgets in dollars, tokens or both, per turn, day, week, month or for good, in any time zone.
- Judges that ask a model yes-or-no questions about a call, and decide by the probability of yes.
- `WardrikPolicy.Middleware`, which holds a WardrikCore agent to its policies, parks calls that ask,
  and reports every decision as a telemetry event and on its step's span.
- A parked call's `WardrikPolicy.Ask` names its `interrupt` and `message`, and the middleware emits
  the protocol's `wardrik.tool_call.denied` and `wardrik.interrupt.resolved`.
- Gated calls wait for a person once the run has read content from outside, unless `allow_after`
  allows them after that label. A judge's allow holds only before. Asks and decision events carry
  the run's labels.
