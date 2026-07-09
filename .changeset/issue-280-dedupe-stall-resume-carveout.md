---
bump: patch
type: Fixed
---

- **Stall-backstop auto-resume is no longer swallowed by the implement-run deduper.** When the
  cloud stall backstop re-dispatches a stalled `/devflow:implement` run, the resume comment is
  posted while the original run is still `in_progress` (it fires from that run's own trailing
  `always()` backstop step), so the new run's gate dedupe used to classify it as a duplicate and
  skip — leaving the audit comment visible but inert. `dedupe-implement-run.sh` now reads the
  triggering comment from `GITHUB_EVENT_PATH` and, when it carries the
  `<!-- devflow:stall-backstop-audit -->` marker every resume comment writes, skips deduping so
  the taking-over run proceeds. The detection lives entirely in the script (not a workflow env),
  so the fix needs no `.github/workflows/` change. The carve-out only ever fails open, so an
  ordinary duplicate command is still deduped normally, and a genuine payload read/parse error
  during marker detection now emits a `::warning::` (instead of being silently swallowed) while
  still falling through to ordinary dedupe. (#280)
