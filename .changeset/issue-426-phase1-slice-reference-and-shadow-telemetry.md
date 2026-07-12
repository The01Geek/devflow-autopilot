---
bump: patch
type: Changed
---

- **Hand off Phase 1 diff slices by file reference, and make shadow telemetry non-droppable.**
  Two bounded review-engine changes, inherited by every consumer repo automatically (no config
  surface, no allowlist entry, no consumer action). (1) `skills/review/SKILL.md` Phase 1.1 now
  authors each >10-file batch's diff slice with a shell-only `awk … >`-redirect that extracts
  the batch's `^diff --git` sections from the already-cached `diff.patch` into a run-scoped slice
  file (no `git` object access — shallow-checkout safe; no *per-file* filename arguments, only the
  fixed run-scoped `diff.patch` operand — space-safe; and a
  redirect rather than `| tee`, so the slice is never echoed to the orchestrator's stdout), and
  Phase 1.2 passes the `devflow:checklist-generator` the slice's *path* instead of inline content
  (the `{DIFF_PATH}` handoff Phase 3 already uses), so the slice never transits the orchestrator's
  context. The slice is gated on the authoring command's **own exit status** plus a guard-class-2
  `test -s` non-empty check, and any observable slice-authoring failure — a non-zero `awk`/redirect
  exit, or a missing/empty slice — falls back to the full `diff.patch` path for that batch (coverage
  preserved, savings forfeited); the single-batch case passes `diff.patch` directly. (2) `skills/review-and-fix/SKILL.md` Step 2.6 makes writing the
  shadow workpad block (with its `step_2_6` telemetry) a single non-optional Write-tool obligation
  fused to the pass's termination, covering **both** paths — Parse-and-compare completion and the
  honest-degradation fail-safe (an outcome-3 pass writes its `not_verified` block before taking
  outcome 3) — plus a blinding-boundary contract sentence forbidding a workpad path or workpad
  content in any shadow prompt. `lib/efficiency-trace.sh --persist` gains a shadow floor that
  synthesizes a minimal `shadow_synthesized: true` + promotion-linkage marker when promotion
  evidence survives with no `shadow` block (promoted-shadows-only; attribution, not cost; never
  overwrites an agent-written block), validated by `--self-check` as a recognized degraded class.
  Both of the floor's write arms now surface the underlying tool's error text — the failing `jq`'s
  message and `mv`'s own errno (read-only mount, `ENOSPC`) — instead of discarding it, so a floor
  that could not write is diagnosable rather than merely reported.
  Reuses command heads already granted in both cloud allowlists — no allowlist change. (#426)
