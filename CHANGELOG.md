# Changelog

## 0.1.0 (unreleased)

- Rules that allow, ask about or deny each tool call, by tool, by what a call acts on, and by its
  arguments. The strictest rule wins, across several policies too.
- Budgets in dollars, tokens or both, per turn, day, week, month or for good, in any time zone.
- Judges that ask a model yes-or-no questions about a call, and decide by the probability of yes.
- `WardrikPolicy.Middleware`, which holds a WardrikCore agent to its policies, parks calls that ask,
  and reports every decision as a telemetry event and on its step's span.
