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
  final pass) while keeping their original triggering conditions and staying repo-agnostic for
  consumer installs. The only body change in either skill is the provenance sentence covered by
  the next bullet (and the clause it was grammatically joined to).
- **Corrected the provenance sentence shipped in `receiving-code-review`.** It read "vendored
  verbatim from `superpowers`" while standing at 9.2x the upstream skill's size, and was
  already divergent at its own import commit — an accuracy defect that reached consumer
  repos. It now reads that the skill originates in the MIT-licensed `superpowers` plugin
  (© 2025 Jesse Vincent) and has been substantially modified by DevFlow.
  `requesting-code-review`, which carried no provenance sentence at all, gains the same line.
- **Every vendored agent now names its DevFlow engine role in its description.**
  `code-reviewer`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`,
  `type-design-analyzer`, `code-explorer`, and `code-architect` all carried descriptions that
  never named DevFlow — six of them byte-identical to the upstream Anthropic plugins they were
  vendored from, and `silent-failure-hunter`'s a DevFlow reflow of upstream's text that still
  read as the same agent — so a user with both installed had no basis to tell the entries
  apart. Each description now opens by naming the agent's role in
  DevFlow's engine (review-engine reviewer, or implement-phase discovery/planning) before the
  unchanged triggering conditions. Agent bodies and tool/model frontmatter are unchanged.
- **The two subagent-only retrospective skills are no longer model-invocable.**
  `retrospective` (Stage A) and `retrospective-audit` (Stage B) both told the model "do not
  call it directly" while still appearing in the skill menu as invocable. Both now carry
  `disable-model-invocation: true`, matching `init`. `/devflow:retrospective-weekly` is
  unaffected — it dispatches each stage by instructing the subagent to read that stage's
  `SKILL.md`, never through the Skill tool.
