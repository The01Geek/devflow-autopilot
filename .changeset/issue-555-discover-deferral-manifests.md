---
bump: patch
---

### Fixed

- Phase 4.0.5 of `/devflow:implement` no longer silently discards deferred review findings when
  manifest discovery degrades. Discovery moved out of a single multi-root `find … | sort` pipeline —
  whose exit status was masked by the pipe and discarded by the command substitution, so a failed
  search and a genuine no-match search were indistinguishable — into the new stdlib-only helper
  `scripts/discover-deferral-manifests.py`, which searches each candidate root independently,
  classifies it `ok`/`absent`/`failed` (including a mid-traversal `OSError`), and reports discovery
  status through both channels: an exit code (0 clean, 3 partial, 4 all-failed, 2 no roots) and a
  fixed stderr marker on each degraded outcome (partial and all-failed only — a clean run and the
  zero-argument usage error emit none). The §4.0.5 fence consumes zero-vs-non-zero from the exit and
  discriminates partial from failed on the stderr marker — the same idiom it already uses for
  `file-deferrals.py` —
  gates filing on a successful discovery, surfaces the helper's per-root roots-echo into the tool
  result on every path, publishes a new `discovery=` field on its unconditional sentinel, and the
  reader-routing arms fail closed so a degraded discovery can no longer be read as the clean no-op.

### Added

- `scripts/discover-deferral-manifests.py` and its implement-tier grant, authored through the
  `lib/capability-profiles.json` capability manifest so `devflow-implement.yml` and
  `matcher-probe.yml`'s `IMPLEMENT` baseline are regenerated in lockstep.
