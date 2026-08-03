---
bump: patch
type: Fixed
---

- **A `/prflow:implement` run no longer wedges when a workpad write fails.** Three changes give the run a defined degradation instead of a dead end. (1) The fix loop's local per-iteration JSON file is now named the *iteration record* in `skills/review-and-fix/SKILL.md`, so the term *workpad* no longer refers both to it and to the GitHub issue comment. (2) The Phase 3.4 acceptance-criteria gate reads through a new degrading `workpad.py acs-gate` subcommand: a workpad read that fails for a reason other than a clean absence is routed to a distinct `workpad-read-failed` label and the criteria are recovered from the issue body via `scripts/parse-acs.py` — never a silent pass — with `unestablished` when the issue body is also unreachable. (3) A workpad change that fails to PATCH is buffered under `.prflow/tmp/` and replayed idempotently on the next successful `workpad.py update`, so a dropped note or reflection survives an outage. (#1214)
