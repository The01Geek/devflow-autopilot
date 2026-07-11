---
bump: patch
type: Changed
---

- **Hand off Phase 1 diff slices by file reference, and make shadow telemetry non-droppable.**
  Two bounded review-engine changes, inherited by every consumer repo automatically (no config
  surface, no allowlist entry, no consumer action). (1) `skills/review/SKILL.md` Phase 1.1 now
  authors each >10-file batch's diff slice with a shell-only `awk … | tee` pipeline that extracts
  the batch's `^diff --git` sections from the already-cached `diff.patch` into a run-scoped slice
  file (no `git` object access — shallow-checkout safe; no filename arguments — space-safe), and
  Phase 1.2 passes the `devflow:checklist-generator` the slice's *path* instead of inline content
  (the `{DIFF_PATH}` handoff Phase 3 already uses), so the slice never transits the orchestrator's
  context. A guard-class-2 `test -s` non-empty check falls back to the full `diff.patch` path on any
  empty/absent slice (coverage preserved, never a thinned review surface); the single-batch case
  passes `diff.patch` directly. (2) `skills/review-and-fix/SKILL.md` Step 2.6 makes writing the
  shadow workpad block (with its `step_2_6` telemetry) a single non-optional Write-tool obligation
  fused to the pass's termination, covering **both** paths — Parse-and-compare completion and the
  honest-degradation fail-safe (an outcome-3 pass writes its `not_verified` block before taking
  outcome 3) — plus a blinding-boundary contract sentence forbidding a workpad path or workpad
  content in any shadow prompt. `lib/efficiency-trace.sh --persist` gains a shadow floor that
  synthesizes a minimal `shadow_synthesized: true` + promotion-linkage marker when promotion
  evidence survives with no `shadow` block (promoted-shadows-only; attribution, not cost; never
  overwrites an agent-written block), validated by `--self-check` as a recognized degraded class.
  Reuses command heads already granted in both cloud allowlists — no allowlist change. (#426)
