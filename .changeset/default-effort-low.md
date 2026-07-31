---
bump: patch
---

### Changed

- Default reasoning effort in the shipped `.devflow/config.example.json` is now `low` for `devflow.effort`, `devflow_implement.effort`, `devflow_runner.effort`, and the `devflow_review.agent_overrides` entries (`default`, `prflow:checklist-deduper`, `prflow:code-reviewer`). The coupled prose in `config.schema.json`, `docs/review-agent-overrides.md`, and the `lib/test/run.sh` guard comment is updated to match. The live `.devflow/config.json` already ran at `low`, so this only changes what fresh installs scaffold.
