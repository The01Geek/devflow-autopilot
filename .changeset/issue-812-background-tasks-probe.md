---
bump: patch
---

### Added

- A `background-tasks-probe` job in `.github/workflows/matcher-probe.yml` and its
  deterministic verdict helper `scripts/background-tasks-probe-verdict.py`, which observe
  whether `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: "1"` — the issue-#801 harness floor on the
  cloud engine steps — actually keeps a dispatched subagent in the foreground inside
  `claude-code-action`. The verdict (FOREGROUND / BACKGROUNDED / NOT_DISPATCHED /
  INCONCLUSIVE) is derived from the run's execution file, never from the model's text
  (PR #835, issue #812).

### Changed

- `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, `docs/implement-skill.md`, and the harness-floor comment
  in `.github/workflows/devflow-runner.yml` now record that floor as **observed effective**
  — the probe measured FOREGROUND on cloud run 30210679122 — instead of stating the premise
  was unobserved. The verdict is version-dependent and is re-probed after a
  `claude-code-action` upgrade (PR #835, issue #812).
