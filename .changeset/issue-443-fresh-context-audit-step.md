---
bump: patch
type: Added
---

- **`/devflow:create-issue` now runs a mandatory fresh-context audit (Step 3.6) before presenting a draft.** After the inline Step 3.5 steelman passes, the skill dispatches one synchronous, information-starved audit subagent (rendered draft title + body only; the drafting conversation, Step 1 findings, and on-disk drafting artifacts are out of bounds) that runs an adversarial pre-mortem audit and returns a `VERDICT: FILE` / `VERDICT: REVISE` line. On `REVISE` the orchestrator verifies each finding against the code, revises, re-gates, and re-audits at most once — the audit informs, it never deadlocks filing. The audit writes an observable `.devflow/tmp/issue-audit-<slug>.md` artifact gating the Step 4 presentation, the presentation carries a one-line audit summary, and consumer repos extend the audit dimensions through a `## Audit dimensions` section in their `create-issue` prompt extension (this repo ships the DevFlow-engine dimensions). Degrades to an inline audit when no subagent tool is available. (#443)
