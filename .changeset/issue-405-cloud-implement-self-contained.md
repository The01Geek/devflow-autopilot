---
bump: patch
type: Changed
---

- **Cloud `/devflow:implement` is now self-contained: in-run verification happens in the run's own environment, never via CI.** The implement run runs the project's test/lint commands in-env (granted through `devflow_implement.allowed_tools` / `devflow.allowed_tools`) and ticks every verification-command acceptance criterion — and the inline review pass's test evidence — on the pass it observes there. It no longer waits on, polls, or cites CI for its own progress; a verification command that is not granted goes **Blocked** naming `devflow_implement.allowed_tools` as the remedy instead of silently deferring to CI. CI remains the required post-PR check that gates the human merge. Auto-resume runs now invoke bundled helpers with the repo-relative vendored literal (`.devflow/vendor/devflow/scripts/…`) as the leading token — the only form the cloud allowlist grants — so a resumed run actually resumes instead of dying on a silently-denied first helper call. (#405)
