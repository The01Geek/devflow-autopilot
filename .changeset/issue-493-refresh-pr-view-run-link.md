---
bump: patch
type: Added
---

- **Refresh the draft PR's `View run` link on `/devflow:implement` resume.** On a
  resumed cloud run that reaches the §1.4 Resume pre-check and finds an existing
  open PR, the draft PR body's `[View run](...)` line (written once at Phase 3.1
  and previously never touched again) is now rewritten to the resumed run's URL
  via a best-effort REST `gh api` PATCH, mirroring the gate job's workpad
  `Run:`-link refresh contract. It is cloud-only (`GITHUB_RUN_ID` non-empty),
  idempotent (the Phase 3.1-placed line is replaced in place, never appended),
  and never blocks the resume — every failure path emits a `::warning::`
  breadcrumb naming the step and continues. Only the `[View run]` line
  immediately following the `Resolves #` line is rewritten; a human-added one
  elsewhere is preserved byte-for-byte. The single-line rewrite is a
  deterministic, fixture-tested helper (`scripts/refresh-pr-run-link.py`), and
  its output is captured and guarded non-empty before the PATCH so a crashed
  transform can never blank the PR description; both the read and the write use
  repo-scoped REST `gh api`. (#494)
