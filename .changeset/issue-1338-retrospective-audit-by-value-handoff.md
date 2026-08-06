---
bump: patch
---

### Fixed

- The Stage B retrospective subagent brief (`skills/retrospective-audit/SKILL.md`) no
  longer reaches for bundled helpers through the `${CLAUDE_SKILL_DIR}` anchor. A
  dispatched subagent receives neither that variable nor a runner-reported base
  directory, so those six invocations could not resolve — including the brief's *only*
  sanctioned JSON-build route (`run-jq.sh`), under a "never hand-write or heredoc JSON"
  hard rule — their prescribed stop-and-report failure arm would have broken the brief's
  exactly-one-JSON-object stdout contract, and one of them (`load-prompt-extension.sh`)
  resolves its default path with `git rev-parse`, which the brief forbids. The
  orchestrator (`skills/retrospective-weekly/SKILL.md`) now resolves the bundled-helper
  root itself and hands it to the child **by value**, extending the by-path `<REPO_ROOT>`
  handoff it already performed and reusing the same resolution PR #1336 shipped for Stage
  A. The child resolves nothing, invokes no helper that touches git, and reports every
  residual through its JSON contract rather than as prose on stdout. The duplicated
  anchor-resolved `load-prompt-extension.sh` fence is removed — the orchestrator's by-path
  extension handoff is the single route.
