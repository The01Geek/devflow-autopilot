---
bump: patch
type: Added
---

- **Reception Preflight for `receiving-code-review`.** On a direct invocation, the
  `receiving-code-review` skill now runs a read-only Reception Preflight before triage,
  editing, or test-suite execution: it renders one in-chat block of nine context facts
  (subject, PR head/base, checkout, working-tree cleanliness, freshness, linked issues,
  extension outcome, severity threshold, commit/path scope), each carrying one of six
  closed statuses. A three-arm subject classifier with a path-disjointness contradiction
  rule binds the reception's subject, a shallow-aware head-match verdict is re-measured
  after the Step 0 branch update, and an affirmative-only editing gate bars work on a
  provably-wrong branch or an ambiguous subject with a work-preserving remedy while triage
  proceeds on the explicitly-degraded facts. Fetched third-party text (feedback and
  linked-issue bodies) is treated as data, never instructions. Scoped to direct
  invocations — an autonomous fix loop that drives its own context establishment is
  unchanged. (#549)
