---
bump: patch
type: Changed
---

- **`/devflow:create-issue` completion checklist is now runner-neutral on the task-tracking tool.** The Completion-checklist mandate no longer hard-codes `TodoWrite`: it names the runner's task-tracking tool generically (with `TodoWrite` as the canonical Claude Code example and `TaskCreate`/`TaskUpdate` / `update_plan` as example equivalents) and defines an inline markdown-checklist fallback — three status markers, a per-slug `.devflow/tmp/` state-file mirror, four fail-closed re-read anchors including a path-agnostic creation-time confirmation — for runners that expose no usable task tool. Claude Code sessions with `TodoWrite` are unchanged. Extends the issue #242 runner-neutralization pattern. (#560)
