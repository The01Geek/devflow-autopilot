---
bump: patch
---

Extend the read-only generated-artifact drift preflight to the sanctioned shard-decomposition route (issue #1288).

The pre-launch drift preflight (issue #1244) was coordinator-only, so the #1132 decomposition route — the one a run takes when the tier terminates the parallel coordinator at its per-command execution ceiling — ran `lib/test/run-shard.sh` per shard and recombined without any pre-launch drift check, paying the full sharded suite to rediscover a stale generated artifact a sub-second read-only check would have named before launch.

`lib/test/run-parallel.sh` now exposes the same check as a standalone `--preflight` mode: it launches no shard and exits with the coordinator's exact verdict contract — proceed on clean or a fail-open inconclusive result, refuse only on a positively-attributed drift. The verdict interpretation is factored into a single shared function so it stays single-sourced rather than duplicated into a second coupled shell copy. `.prflow/prompt-extensions/implement.md`'s decomposition route names `lib/test/run-parallel.sh --preflight` once before its shard loop.
