---
bump: patch
type: Changed
---

- **The two vendored review skills now name DevFlow's engine context in their descriptions.**
  `receiving-code-review` and `requesting-code-review` are hard forks of the upstream
  `superpowers` skills, but neither description named DevFlow, so a session with both
  plugins installed listed two similarly-described skills with no basis to pick the DevFlow
  fork. Each description now opens by naming the DevFlow surface the skill serves (the
  review-and-fix loop; the review engine's final pass) before its original, unchanged
  triggering conditions — the same prepend-a-role-sentence shape the agent descriptions
  below use, so each skill's original trigger conditions are preserved verbatim and both
  stay repo-agnostic for consumer installs. The only body
  change in either skill is the provenance sentence covered by the next bullet (and the
  clause it was grammatically joined to).
- **Corrected the provenance sentence shipped in `receiving-code-review`.** It read "vendored
  verbatim from `superpowers`" while the skill's body has been substantially rewritten for
  DevFlow — an accuracy defect that reached consumer repos. It now reads that the skill
  originates in the MIT-licensed `superpowers` plugin (© 2025 Jesse Vincent) and has been
  substantially modified by DevFlow.
  `requesting-code-review`, which carried no provenance sentence at all, gains the same line.
- **Every vendored agent now names its DevFlow engine role in its description.**
  `code-reviewer`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`,
  `type-design-analyzer`, `code-explorer`, and `code-architect` all carried descriptions that
  never named DevFlow and still read as the upstream Anthropic agents they were vendored
  from, so a user with both installed had no basis to tell the entries apart. Each
  description now opens by naming the agent's role in DevFlow's engine (review-engine
  reviewer, or implement-phase discovery/planning) before the unchanged triggering
  conditions. Agent bodies and tool/model frontmatter are unchanged.
- **The two subagent-only retrospective skills are no longer model-invocable.**
  `retrospective` (Stage A) and `retrospective-audit` (Stage B) both told the model "do not
  call it directly" while still appearing in the skill menu as invocable. Both now carry
  `disable-model-invocation: true`, matching `init`. `/devflow:retrospective-weekly` is
  unaffected — it dispatches each stage by instructing the subagent to read that stage's
  `SKILL.md`, never through the Skill tool. (#911)
