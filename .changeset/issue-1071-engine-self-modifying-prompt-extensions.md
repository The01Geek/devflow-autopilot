---
bump: patch
---

Phase 0.5 now classifies a prompt-extension diff (any `.md` file under the `.prflow/` or `.devflow/` state directory, at any depth) and a `CLAUDE.md` diff (basename match, any depth) as `engine_self_modifying`, so such a diff reaches the full Phase 1+2 checklist and the early shadow rather than the lean config-only path — including in a consumer repository, with no configuration required. The reviewer's own appended instructions and the root agent-instruction file are no longer reviewed as inert config. (#1142, closes #1071)
