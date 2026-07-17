---
bump: patch
---

create-issue: bind one successfully-writable canonical draft root per run (issue #562)

The `scripts/issue-audit-state.py` audit-lifecycle state owner gains a tiered
canonical-draft-root binding. A run records exactly one bound draft root (its absolute
path, a bound-tier token from the closed set `main-root` / `worktree-root`, and the
divergent non-bound root when both a resolver-answered main root and a divergent
worktree root exist) via a new once-per-run `record-draft-binding` mutation; the draft
digest, `approve`-mode eligibility, and body-emitting operations resolve the draft file
from that recorded binding rather than trusting a caller-supplied path that a compacted
context could drift.

Two coordination deltas land alongside: revision records may carry the revised bytes'
stdin digest (`record-revision --stdin-digest`), and a canonical-write failure at the
bound path is recorded (`record-write-failure`). The file-arm `approve` eligibility
ground now requires — beyond byte-digest equality — that no revision record postdates the
clean round, so a recorded revision whose overwrite failed (the bound file still holding
the prior round's byte-identical bytes) answers `not-eligible` / `unaudited-revision`
instead of being waved through on stale byte-identity. A `query-draft-binding` query and
new `query-summary` fields (`bound_root`, `bound_tier`, and the derived
`draft bound to worktree root` marker) expose the binding so the display and the
divergent-roots enumerations obtain their operands from the tool. The state
`schema_version` is bumped to 2.
