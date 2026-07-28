---
bump: patch
type: Changed
---

- **The two vendored review skills now name DevFlow's engine context in their descriptions.**
  `receiving-code-review` and `requesting-code-review` are hard forks of the upstream
  `superpowers` skills whose triggering metadata was byte-identical to their upstream
  originals, so a session with both plugins installed listed two skills with the same
  description and no basis to pick the DevFlow fork. Their descriptions now name the DevFlow
  trigger surface (a DevFlow review verdict / the review-and-fix loop; the review engine's
  final pass) while staying repo-agnostic for consumer installs. Bodies are unchanged.
- **Six vendored agents now name their DevFlow engine role in their descriptions.**
  `code-reviewer`, `comment-analyzer`, `pr-test-analyzer`, `type-design-analyzer`,
  `code-explorer`, and `code-architect` carried descriptions byte-identical to the upstream
  Anthropic plugins they were vendored from, so a user with both installed saw duplicate,
  indistinguishable entries. Each description now opens by naming the agent's role in
  DevFlow's engine (review-engine reviewer, or implement-phase discovery/planning) before the
  unchanged triggering conditions. Agent bodies and tool/model frontmatter are unchanged.
- **The two subagent-only retrospective skills are no longer model-invocable.**
  `retrospective` (Stage A) and `retrospective-audit` (Stage B) both told the model "do not
  call it directly" while still appearing in the skill menu as invocable. Both now carry
  `disable-model-invocation: true`, matching `init`. `/devflow:retrospective-weekly` is
  unaffected — it dispatches each stage by instructing the subagent to read that stage's
  `SKILL.md`, never through the Skill tool.
