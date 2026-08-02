---
bump: patch
type: Changed
---

- **Trimmed unconsumed output-format sections from the Phase-3 review agents.** The review
  agents mandated output sections the engine never consumes — `Positive Findings`
  (`comment-analyzer`), `Positive Observations` (`pr-test-analyzer`), and `### Strengths` /
  `### Recommendations` (the vendored `requesting-code-review` final-pass template) — that were
  authored on every dispatch and discarded. Removing them shortens reviewer returns across every
  `/prflow:review-and-fix` iteration and both shadow fan-outs, lowering orchestrator context
  pressure and the compaction risk it drives. Each agent's severity rubric, finding machinery,
  clean-run evidence, and the template's `### Assessment` verdict are untouched. The read-only
  working-tree policy is normalized to one identical `## Working-tree policy (read-only, advisory)`
  heading across all five first-party review agents, and the final-pass dispatch fence now names
  the sections the template actually defines. (#1080)
