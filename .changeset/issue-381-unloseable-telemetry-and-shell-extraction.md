---
bump: patch
type: Added
---

- **Unloseable review-loop telemetry: `iter-<N>.json` emit fused to the fix commit, plus a synthesis floor.** `/devflow:review-and-fix` now anchors the per-iteration workpad Write to Step 3 item 6's fix-commit moment (no seam between "fix landed" and "record exists"), and `lib/efficiency-trace.sh --persist` reconstructs a minimal iteration record (`iter` / `fix_commit_sha` / `fix_files` / `loop_role` / `synthesized: true`) from the branch's `fix: address review findings (iteration N)` commits when a run left zero `iter-*.json` — so a fully-dropped run still contributes effectiveness telemetry. `efficiency-trace.jq` and `--self-check` recognize the synthesized class. (#381)
- **Workflow inline-shell extraction convention.** `CLAUDE.md` and `phase-2-implement.md` §2.3 now state that inline shell in a workflow that selects a branch or composes a user-facing message is extracted into a `scripts/*.sh` helper so the suite can drive each branch — a grep-pin on a message literal is not coverage of the selection that chooses it (reference: `scripts/describe-denial-count.sh`, #367). (#381)
