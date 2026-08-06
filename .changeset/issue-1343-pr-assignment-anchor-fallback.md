---
bump: patch
type: Fixed
---

- **Implement Phase 3.1.1 now emits the granted vendored literal for the PR-assignment helper, with the portable anchor retained as a fallback arm.** The call site previously prescribed the bare `${CLAUDE_SKILL_DIR:-…}` anchor as its leading token — a shape the cloud matcher denies (issue #1124) — so cloud implement runs assigned the triggering user only intermittently. It now emits `.prflow/vendor/prflow/scripts/apply-pr-triggerer.sh <draft-pr-number>` first and falls back to the anchor form only when the vendored path is absent, matching the tier-agnostic remedy already used for the `load-prompt-extension.sh` call sites. The site is also enrolled in `lint-anchor-fallback-arm.py` so a future edit that drops the fallback arm turns the suite RED. (#1343)
