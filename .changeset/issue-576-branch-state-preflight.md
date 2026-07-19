---
bump: patch
type: Added
---

- **Add the `preflight.py branch-state` ahead-of-base branch preflight (Verdict B).** A new
  `branch-state` subcommand classifies the adopted/working branch against the base and emits a
  one-token verdict + matching exit code (`FRESH`/`VALIDATED_RESUME` → 0, `AMBIGUOUS`/`DECISION_BLOCKED`
  → 2, `UNAVAILABLE` → 3), mirroring `update-branch-checkpoint.sh`'s one-token-stdout contract. It
  derives the ahead-of-base count (with shallow unshallow-once-then-rederive), recorded-branch
  existence, and published-tip reachability, closing the blind spot where a branch carrying unrelated
  ahead-only history reads "up to date" against the behind-only freshness guard and publishes foreign
  commits into the PR. Phase 1 §1.4.0.5 runs the classification on the adopted-branch arm, after branch
  determination and before the §1.4.1 checkpoint and §1.5 push, so a stop verdict aborts before any
  history mutation. (#576)
