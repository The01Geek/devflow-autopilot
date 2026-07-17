---
bump: patch
---

### Changed

- `/devflow:create-issue`'s fresh-context audit lifecycle is now owned by a bundled, tested
  state-owner CLI (`scripts/issue-audit-state.py`) instead of procedural prose in the skill.
  The tool validates every transition, enforces the ported budgets and bounded retries,
  computes and compares all draft-identity digests, generates and checks the carriage
  evidence, evaluates the user-chosen-round offer triggers, decides presentation
  eligibility, and emits the audit-summary fields from recorded state. Observable
  lifecycle semantics are ported, not redesigned. The skill keeps the audit *reasoning* —
  the audit-prompt template, dimension checklist, information diet, out-of-bounds lists
  and extension forwarding — plus the subagent dispatch, the `VERDICT:` token parse, the
  draft-file writes and every user interaction; issue posting stays skill-side too.
  Run state persists to `.devflow/tmp/issue-audit-state-<slug>.json`, replacing the
  markdown event log (issue #546, PR #547).

- Presentation eligibility is now a real gate rather than a prose rule: only the current
  draft counts as audited, grounded on a completed clean-verdict round whose recorded
  identity still holds (byte-digest equality on file-arm epochs; revision ordering on the
  embed and inline arms, where no trustworthy canonical file exists), or on an explicitly
  recorded override that has not been invalidated by a later revision. Every `eligible`
  answer carries a deterministic, digest-bound eligibility token that the audit summary
  line quotes verbatim, so a presentation whose summary lacks the matching current token is
  detectable in the transcript. This **narrows** the prose-compliance gap the motivating
  incident exposed — it does not close it, because no in-process component can force an
  orchestrator that never invokes it (issue #546, PR #547).

- Issue creation is bound to the audited bytes: on file-arm epochs the posted body is
  sourced from the gated canonical draft through the tool's body-emitting query, and every
  creation is followed by a best-effort attestation that hashes the created issue's fetched
  body against the recorded body-only digest. A mismatch is surfaced in the reported outcome
  and the audit-summary fields (post-hoc detection — creation is not rolled back), and a
  failed fetch is reported as attestation-unavailable, never as a pass (issue #546, PR #547).

- On hosts where the state owner cannot run (an absent interpreter, a denied invocation, an
  unpersistable state file), the skill now routes to a named, bounded fallback lifecycle —
  one audit round, findings kept in-chat, a single continue/decline choice, and the distinct
  `state-owner unavailable` marker on the audit summary line — rather than the full prose
  state machine it used to fall back to. This is an acknowledged behavior change on such
  hosts. The existing `degraded` marker keeps its current meaning (the inline audit arm)
  (issue #546, PR #547).
