---
bump: patch
---

Retrospective cheap-gate now fails closed on an absent workpad. `lib/fetch-pr-context.sh`
emits non-empty `workpad_final_status` sentinels — `NoIssue` (no linked issue resolved) and
`Absent` (issue resolved but no workpad comment) — alongside the existing `Unparsed`, plus a
new top-level `pr_devflow_provenance` boolean (true iff the `DevFlow` label is on the PR or the
resolved issue). `lib/cheap-gate.jq` shrinks its clean set to `Complete` only: `""`/`null`/an
absent key now gate non-clean with the reason `workpad absent or status unknown`. A new
suite-driven helper `lib/dispatch-disposition.jq` mechanically decides skip-vs-dispatch for
non-clean bundles before any LLM dispatch — a foreign, issueless, non-DevFlow PR whose only
non-clean signal is an absent workpad is skipped (with a visible one-line report record and a
`kind: "skip"` marker entry), while a DevFlow run that merely lost its audit trail is analyzed.
Stage A (`skills/retrospective/SKILL.md`) gains a workpad-absent analysis rule and re-keys its
two defined skips (interim, `Cancelled`) to a `"skip"` key distinct from a genuine `"error"`.
The marker-entry consumers of `retrospectives.jsonl` are reconciled to the new record type.
