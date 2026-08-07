---
bump: patch
type: Fixed
---

- **Reworded the implement skill's `prflow:docs` dispatch shorthand.** The Phase 4.1 documentation pass was described across nine sites as "the `prflow:docs` subagent", which reads as an Agent type and invited a failing `subagent_type: prflow:docs` dispatch. Each site now names it as the `prflow:docs` skill invoked inside a general-purpose subagent, matching the already-correct §4.1 dispatch instruction. (#1381)
