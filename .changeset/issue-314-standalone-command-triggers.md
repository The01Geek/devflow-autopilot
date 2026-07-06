---
bump: patch
type: Fixed
---

- **Light `/devflow:*` command triggers now fire only on a standalone command, not a quoted mention.** `scripts/resolve-command-trigger.sh` now detects `/devflow:review`, `/devflow:review-and-fix`, and `/devflow:pr-description` via a shared markdown-aware line scanner (`scripts/detect-standalone-command.sh`) that recognizes a command only when it is the sole content of its own line — anchored, fence-aware, indent-aware, most-specific-first, and fail-closed on an unbalanced fence — so a command merely quoted in prose, blockquoted, indented, or inside a fenced code block no longer starts a spurious review run (the reported PR-review self-trigger loop). A self-marker guard additionally declines any body carrying a DevFlow self-comment marker (the review-progress prefix or the workpad marker) before authorization. (#318)
