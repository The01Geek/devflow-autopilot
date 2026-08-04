---
bump: patch
type: Fixed
---

- **Dispatching skills now assert that invoking them constitutes the user's request for subagent dispatch.** Recent Claude Code versions inject a conditional instruction ("do not call the AgentTool unless the user requested it") observed on Opus 5; because no skill asserted the condition was met, dispatch could silently collapse to inline work. Each dispatch-dependent skill (`implement`, `review`, `review-and-fix`, `create-issue`, `retrospective-weekly`, `requesting-code-review`) now carries a scoped authorizing clause naming only its own dispatch points, satisfying the injected condition without weakening the existing restrictive rules or granting dispatch for inline work. (#1200)
