---
bump: patch
type: Fixed
---

- **Route the review engine's consumer-prompt-extension loads through the cloud-granted
  vendored literal, keeping the portable anchor as a fallback arm.** The cloud matcher
  denies the unexpanded `${CLAUDE_SKILL_DIR:-…}` anchor as a leading token, so
  `skills/review/SKILL.md` and both `load-prompt-extension.sh` invocations in
  `skills/review-and-fix/SKILL.md` now emit `.prflow/vendor/prflow/scripts/…` first (the
  #1256 tier-agnostic form) and fall back to the anchor for the local and non-Claude-Code
  tiers, so the load executes on the cloud tiers while staying portable everywhere else. A
  new desk-time gate `lib/test/lint-anchor-fallback-arm.py` fails when an enrolled
  cloud-reachable call site emits the anchor leading token with no vendored fallback arm,
  and the anchor's argument-position denial (run `30695072336`) is recorded in
  `docs/cloud-allowlist.md`. (#1124)
