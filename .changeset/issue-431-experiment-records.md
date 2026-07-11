---
bump: patch
type: Added
---

- **Unified experiment record — join run cost to review outcome.** A new
  `scripts/build-experiment-records.py` assembles one tracked line per merged PR into
  `.devflow/learnings/experiment-records.jsonl`, joining each PR's per-run efficiency cost
  (both slug families, as a per-run list) to its retrospective entry, shape-selected review
  verdict, Important-finding count (via the engine's `review.commit_id` ↔ `Reviewed HEAD:`
  join), permission-denial count, and config fingerprint — idempotent, incremental, and
  missing-source-tolerant. `/devflow:retrospective-weekly` invokes it best-effort between
  Materialize and the state PR; `lib/open-state-pr.sh` commits the store. (#431)
- **Denial-count durability.** `devflow-review.yml`'s finalize step now includes
  `permission_denials_count` verbatim in the `Devflow Review` check-run summary, making it
  durable and API-retrievable for every PR (including zero-denial runs); `unavailable` is
  preserved and no path coerces an unestablished count to `0`. (#431)
- **Attribution & completeness.** `lib/efficiency-trace.sh --mode record` stamps a
  `config_fingerprint` naming the config variant that produced the run, and the assembler
  derives a per-record `telemetry_complete` flag so analyses exclude degraded records instead
  of averaging them in. Per-fix `verification_evidence` (command / result / duration) is now
  recorded in the review-and-fix iteration workpad. (#431)
