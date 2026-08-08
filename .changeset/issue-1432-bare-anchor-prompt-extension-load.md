---
bump: patch
---

Fix the `pr-description`, `docs-sync-internal`, `docs-sync-external`, and
`docs-release-notes` skills, whose consumer prompt-extension load emitted only the
bare `${CLAUDE_SKILL_DIR:-…}` anchor as the helper's leading token — a form the
cloud implement matcher denies and a subagent cannot resolve, so their consumer
policy was silently dropped on the cloud implement tier (PR #1438, issue #1432).
Each now emits the granted vendored literal
`.prflow/vendor/prflow/scripts/load-prompt-extension.sh <name>` first, falling back
to the repo-relative and anchor forms, matching the review/implement template;
`pr-description` also gains a render-time placeholder. A lint enrolls all four call
sites so the arm cannot regress.
