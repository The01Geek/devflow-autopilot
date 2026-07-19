---
bump: patch
---

### Added

- `/devflow:create-issue`'s audit lifecycle records a **per-finding ledger** at REVISE
  adjudication, so a drafter who revised and verified every finding fixed can clear the
  round instead of reading `t1=hold` / `converged=no` forever (PR #612).
  `record-adjudication` gains a required `--ledger-stdin` on a REVISE verdict with a
  settled count, reading one status-prefixed summary per must-revise finding through a
  quoted-delimiter heredoc; summaries that forge a `<field>=` token of the tool's printed
  protocol vocabulary are refused, because ledger text is identity data, never protocol.
- Three post-close channels on `scripts/issue-audit-state.py`: `record-resolution` (binds
  named entries to a recorded revision ordinal, cross-round), `record-reopen` (an
  honest regression channel), and `record-invalidate` (retires a misclassified finding
  with a mandatory reason rather than recording a fix that never happened).
- A read-only `query-findings` query — one line per ledger entry, the tool's one
  multi-line query — as the durable read-back the orchestrator reconciles a later round's
  findings against, so the mechanism survives a context compaction.

### Changed

- The T1 offer trigger and `query-convergence` now consume the **run-wide effective**
  unresolved count rather than the count frozen at round close, and convergence reports
  its basis: `basis=adjudicated` when the auditor's own FILE verdict vouches for the
  state, `basis=resolution` when the count reached zero through self-verified post-close
  changes, and `basis=resolution-stale` when an entry's verification predates a later
  revision. `query-summary` gains `effective_unresolved=` and `convergence_basis=`,
  rendered before the trailing `attestation=` field.
- `record-adjudication` is now **write-once** per round — the treatment its sibling
  records already had — with the three post-close channels named as the sanctioned way a
  round's effective count changes after close. A FILE adjudication supersedes every prior
  unresolved ledger entry, so an auditor-accepted clean round still converges the run
  exactly as before.
- The convergence definition no longer claims to be evaluated "within the existing
  automatic audit budget" — a clause `evaluate_convergence` never computed; budget
  legality is enforced upstream at round funding.

### Fixed

- The `#551` prompt-mass census fixture pinned its scratch repo's initial branch, so a
  desk whose `init.defaultBranch` is `main` no longer sees an unrelated RED.
