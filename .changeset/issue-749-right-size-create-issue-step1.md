---
bump: patch
---

### Changed

- `/devflow:create-issue` Step 1 now runs a two-arm, duty-floor-bounded docs-verification pass
  instead of one unconditional whole-repository sweep. A pre-pass judgement of the duties a topic
  engages selects a shallow arm (one peer over the union of both legs) or a deep arm (two parallel
  peers over disjoint legs — the `.docs.internal` location, and the tracked tree minus that
  subtree, both enumerated from the git index). The verdict token drives escalation only, never
  arm selection.
- `/devflow:docs-verify` report-only mode is bounded by a six-duty floor rather than by the size of
  the search space, returns a status for every duty with a bearing observation on each
  judged-not-engaged one, and accepts an
  explicit `--search-space` operand that both its locate-documentation and search-codebase steps
  read. A report-only pass dispatches no subagent of its own; escalation is a return-value contract.

### Added

- Step 1 writes a run-scoped evidence artifact `.devflow/tmp/issue-step1-<slug>.md` (the
  orchestrator, never a peer, on both arms) and binds the run slug behind the fixed pointer
  `.devflow/tmp/issue-run-slug`, which later steps read instead of re-deriving one.
- A bounded inline degraded arm for a failed, unavailable, rejected, or anchor-unresolvable pass.
  It breadcrumbs the failure kind and never terminates the run.
