---
bump: patch
type: Fixed
---

- **The `/devflow:implement` workpad Run link now stays current across stall/retry resumes, and the draft PR links back to the run that created it.** When the cloud `gate` job's early-workpad step finds an existing workpad (a re-trigger or a stall-backstop auto-resume), it now deterministically rewrites the workpad's `**Run:**` link to the current run via `workpad.py update --run-link`, at the workflow level — so an operator watching a stalled/retried run can click straight from the issue workpad to the currently-active job's logs instead of the original run's. This write is best-effort (a `::warning::` breadcrumb, then exit 0) and lands regardless of whether the subsequent `claude` job goes on to execute Phase 1.3. Separately, the Phase 3.1 draft-PR body now carries a `[View run](...)` line under `Resolves #{issue_number}`, omitted entirely on a local-tier run (no GitHub Actions run) rather than rendering a broken link, so a reviewer can trace a mid-run draft PR back to its originating run. (#302)
