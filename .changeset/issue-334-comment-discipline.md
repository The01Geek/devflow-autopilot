---
bump: patch
type: Added
---

- **`/devflow:implement` now writes comments under an explicit two-point discipline.** A new
  Phase 2.3 authoring rule tells the implementer to author only comments that state a
  constraint the code cannot show for itself (rationale, cross-file contracts, portability
  traps, provenance) and to keep mirror-fact comments — exact counts, enumerated site/value
  lists, predicate-restating scope words, and narration of adjacent code — out of the diff or
  make them drift-proof (bind to a test assertion, state a lower bound, or point at the
  defining symbol). A new step in the always-on 2.3.4a self-authored-claim sweep drift-proofs
  the mechanically-detectable mirror-fact comments the diff adds or changes — exact counts,
  enumerated site/value lists, and predicate-restating scope words — before commit, even when
  they are currently accurate, so the rot-prone class is caught whether or not the writer
  applied the authoring rule. Every consumer repo inherits both engine halves, reducing
  stale-comment review findings and fix-loop iterations. (#336)
