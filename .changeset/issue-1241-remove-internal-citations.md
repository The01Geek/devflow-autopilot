---
bump: patch
type: Fixed
---

- **Removed PRFlow-internal issue/PR and acceptance-criterion citations from consumer-shipped
  skill and agent bodies.** `skills/**` and `agents/**` ship verbatim into every consumer repo,
  so a `(issue #441)` / `(#524)` / `(AC5)` citation resolved against this project's own tracker
  and pointed at nothing in a consumer's checkout. The provenance is now stripped while every
  sentence's meaning and binding force are preserved, and a genuinely-instructive citation (an
  autolink-rendering example, an upstream `cli/cli#5398` reference) is kept behind an explicit
  `pruned-path-ok` declaration marker. `lib/test/lint-shipped-pruned-path.py` now fails the suite
  on any new unmarked issue/PR-number or acceptance-criterion citation in that population. (#1241)
