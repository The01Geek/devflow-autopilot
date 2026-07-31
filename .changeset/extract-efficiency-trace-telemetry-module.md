---
bump: patch
---

### Changed

- Extracted the efficiency-trace and telemetry-persistence coverage out of `lib/test/run.sh` into the focused module `lib/test/modules/efficiency-trace-telemetry.sh`, run on the `modules-large` CI shard. The move is assertion-conserving — the module's tally is exactly the assertions that left the monolith — and shortens the `monolith` shard's wall clock, which had been the slowest required-check shard.
