---
bump: patch
---

### Added

- `/devflow:create-issue`'s audit lifecycle records a **per-finding ledger** at REVISE
  adjudication, so a drafter who revised and verified every finding fixed can clear the
  round instead of reading `t1=hold` / `converged=no` forever (PR #612). What this fixes
  is the *reporting* deadlock, not the boundary offer itself: a run cleared this way still
  fires the offer through T2, now carrying a self-verified-resolution message that says the
  revised bytes were never re-audited.
  `record-adjudication` gains a required `--ledger-stdin` on a REVISE verdict with a
  settled count, reading one status-prefixed summary per must-revise finding through a
  quoted-delimiter heredoc; summaries that forge a `<field>=` token of the tool's printed
  protocol vocabulary, or that embed a record-splitting newline or carriage return, are
  refused, because ledger text is identity data, never protocol.
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
- The boundary offer gains one arm no trigger can fire: a `REVISE` round adjudicated with an
  `unestablished` count records no ledger, so once a later ledgered round becomes the latest
  completed round its findings are invisible to both T1 and T2. The skill now directs the
  orchestrator to detect that itself — a gap in the round numbers `query-findings` returns,
  alongside a `basis=resolution` convergence answer — and offer one more audit round on that
  ground. `record-invalidate --reason`'s help and the skill's ledger-summary refusal list
  additionally now name the record-splitting newline/carriage-return refusal both already
  enforced, so a caller meeting `reason-control-char` is no longer met by an undocumented
  refusal. A `_LEDGER_STATUSES` / `_LEGAL_SETTLING_KEYS` drift now fails fast at import with
  a named error instead of surfacing as a raw `KeyError` from inside the read boundary.
- Ledger summaries can no longer forge the `bound=` or `latest_revision_landed=` fields. Both
  are emitted by `query-draft-binding` but were absent from the protocol vocabulary, so the
  forge guard refused their siblings on the same printed line and waved these two through.
- A ledger entry recorded `resolved` while carrying *both* settling-provenance keys is now
  refused at the read boundary. The combination is unreachable by the writer but writable by
  hand, and on it the ingest short-circuit skipped the recorded-revision check entirely.
- `supersession_round` joined the shared settling-key set, so the read boundary's residual-key
  arm covers it and `_clear_settling` is genuinely status-agnostic as documented.
- The boundary-offer arm above now keys on a two-operand predicate — the round numbers
  `query-findings` returns compared against `query-summary`'s `rounds_run=` — because the
  gap-only form missed the residual's base case, where the unledgered round is the *first*
  one and its absence leaves no gap to see. The skill also now treats a `findings=none`
  carrying any `reason=` as an unreadable ledger rather than an empty one at both sites that
  consume the read-back, and names the `ledger-unresolved-count` refusal in its enumeration.
