---
bump: patch
type: Added
---

- **Measure whether a dispatched subagent's `Write` into `.devflow/tmp/**` succeeds on the review and implement tiers.** `matcher-probe.yml` gains two dedicated jobs (`subagent-write-review-probe`, `subagent-write-implement-probe`), each consuming its tier's resolved allowlist via `needs:` (the two existing tier jobs now expose a `tools` output) plus `Task,Agent`, dispatching one built-in `general-purpose` subagent that writes a side-effect file with no orchestrator write of its own. A new `scripts/subagent-write-probe-verdict.py` helper derives a three-outcome verdict (PERMITTED / DENIED / `unestablished`) from the execution file's `permission_denials`, `tool_use` inputs, and `parent_tool_use_id` chains, reporting the recorded-at-all and chain-attributable control facts independently. Repo-internal only — `matcher-probe.yml` is not shipped by `install.sh`, no generated allowlist region changes, and no consumer run is affected. (#858)
