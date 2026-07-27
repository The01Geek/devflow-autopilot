---
bump: patch
type: Fixed
---

- **Supply the consumer prompt extension at every subagent dispatch of a DevFlow skill.** A skill dispatched into an isolated subagent (a `general-purpose` Task or an Agent-tool subagent) receives no skill-directory anchor, so its `load-prompt-extension.sh` loader silently no-ops and the consumer's `.devflow/prompt-extensions/<skill>.md` is never honored. The retrospective Stage A/B dispatches and the Phase 4.1 `devflow:docs` dispatch now append a by-path handoff sentence naming the child's extension file as an absolute path, and the two retrospective children report a present-but-unreadable extension via an optional JSON key their parents relay. A new committed registry (`lib/subagent-dispatch-sites.json`) enumerates every such dispatch site, and a new lint (`lib/test/lint-subagent-extension-handoff.py`, wired into the suite) fails the build when a subagent dispatch of a DevFlow skill is added without a registry record. (#834)
