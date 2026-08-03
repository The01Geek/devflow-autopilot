---
bump: patch
type: Added
---

- **Document the `git -C` refusal and deliver the cloud command-shape discipline to dispatched review subagents.** The grounding block's denied-shape list (`scripts/render-grounding-block.sh`) now names `git -C <path> <subcommand>`, so every tier that renders the block carries it; `docs/cloud-allowlist.md` records `git -C` as a refused form (it cannot be granted without matching every git subcommand behind `-C`, including the write ones the read-only review profile excludes) and names the permitted bare `git <subcommand>` alternative. Each review agent definition (`agents/*.md`) now carries a repo-agnostic command-shape discipline in its own body, so a dispatched review subagent receives it independent of the orchestrator's per-dispatch prompt, and `skills/review/phases/phase-3-agents.md` records why that surface (not an appended dispatch paragraph) carries it and that a dispatch prompt gives the agent no absolute filesystem path. (#1231)
