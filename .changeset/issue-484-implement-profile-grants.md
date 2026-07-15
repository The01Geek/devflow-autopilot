---
bump: patch
---

### Added
- Grant the bundled helpers used by cloud implement runs on the implement profile (`devflow-implement.yml`). Phase 3's inline review engine uses `stale-prose-lint.py`, `dismiss-stale-rejections.sh`, `match-lint-adjudications.py`, and `load-prompt-extension.sh`; the implement-owned surfaces use `react-to-trigger.sh` in the trigger-reaction fence and `extract-doc-needed-paths.sh` in Phase 4.1. Grant `cmp` for the inline review engine and `gh pr checkout` in `devflow.yml` for the manual `/devflow:review-and-fix` path (#363).

### Changed
- Anchor bare `workpad.py` fences in `skills/implement/phases/*.md` to the portable inline-anchor form the granted vendored literal covers.
- Rework the `react-to-trigger.sh` emission in `skills/implement/SKILL.md` to a leading-token form with CLI args (a leading `VAR=` env prefix was a denied matcher shape) and record failure rather than swallowing it; `react-to-trigger.sh` accepts `--repo/--event/--comment/--issue/--reaction` CLI flags (env-var path unchanged for the workflow `env:` block).
- `load-prompt-extension.sh`'s guard distinguishes a matcher refusal from "no consumer extension" and records the former as a workpad note.
- Rework `phase-4-documentation.md` §4.1's docs-commit fence so doc paths reach `git add` through printed tool output, not a `VAR=` read across a fence boundary.

### Removed
- Inert `*/`-prefixed grant globs from `.devflow/config.json`'s `devflow.allowed_tools` and `devflow_implement.allowed_tools` — a `*/basename` glob does not match the vendored multi-segment leading token the matcher grants.

### Fixed
- Add a `lib/test/run.sh` head guard (#484) that drives `extract-command-heads.py` (new `implement-block` parse mode) over `skills/implement/**` and `skills/review*/**`, failing when any emitted head is ungranted on the implement profile (allowlist assembled from the workflow alone, with a withheld list and suppression list). Closes #484.
