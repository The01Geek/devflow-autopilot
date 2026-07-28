---
bump: patch
---

### Changed

- Default Claude model moves from Claude Opus 4.8 to Claude Opus 5 (`claude-opus-5`).
  Updates `claude_model` in the shipped `.devflow/config.example.json` and its
  `config.schema.json` default, this repo's tracked `.devflow/config.json`
  (`claude_model`, the `devflow:code-reviewer` agent override, and the
  retrospective/audit models), and the coupled docs mirrors.
