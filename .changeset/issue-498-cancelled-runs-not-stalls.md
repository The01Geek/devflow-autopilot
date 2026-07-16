---
bump: patch
type: Fixed
---

- **Cancelled cloud runs no longer self-resume.** A cancelled `/devflow:implement` cloud run is now a decided ending, not a stall: the implement stall backstop reads `job.status` (`JOB_STATUS: ${{ job.status }}`) and, only on the exact value `cancelled`, flips an interim workpad to a new 🛑 `Cancelled` terminal status (no resume comment, no resume attempt consumed) or `skip-cancelled` on unreadable/auth-failure classes. Every other `job.status` value leaves the existing decision table byte-identical (fail toward resume, so an un-upgraded caller never suppresses a resume). Adds the 🛑 `Cancelled` status to `workpad.py` (glyph vocabulary, recognizer, terminal classification) + the `lib/fetch-pr-context.sh` glyph strip + a defined retrospective Stage-A `Cancelled` skip arm; pins the review-tier cancellation exclusions (`devflow.yml`'s `Review stall backstop` `if:` and `devflow-review.yml`'s `backstop_eligible` emission) as `assert_pin_red_under` regression guards; adds the `cancel-probe` job to `matcher-probe.yml` for the operator-performed live-evidence probe; reconciles every coupled glyph/status site and `CLAUDE.md`. (#517)
