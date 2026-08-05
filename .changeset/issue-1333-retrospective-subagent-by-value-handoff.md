---
bump: patch
---

### Fixed

- The Stage A retrospective subagent brief (`skills/retrospective/SKILL.md`) no longer
  reaches for bundled helpers through the `${CLAUDE_SKILL_DIR}` anchor. A dispatched
  subagent receives neither that variable nor a runner-reported base directory, so those
  invocations could not resolve, their prescribed stop-and-report failure arm would have
  broken the brief's exactly-one-JSON-object stdout contract, and the config reader they
  called resolves its default path with `git rev-parse` — which the brief forbids. The
  orchestrator (`skills/retrospective-weekly/SKILL.md`) now resolves the bundled-helper
  root and the internal-documentation root itself and hands both to the child **by
  value**, extending the by-path `<REPO_ROOT>` handoff it already performed. The child
  resolves nothing, invokes no helper that touches git, and reports every residual
  through its JSON contract rather than as prose on stdout.
