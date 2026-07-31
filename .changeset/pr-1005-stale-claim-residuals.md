---
bump: patch
---

Correct stale self-referential claims left in comments by the Tier 1 `devflow` -> `prflow` rename (#1002 / PR #1005).

`lib/rename-map.json` is the single source of truth for the rename, and its own `_comment` named two reader files that have never existed — `lib/rename_map.py` and `lib/rename-map.sh`. There is no shared loader helper: every reader parses the map itself (`scripts/config-get.sh`, `scripts/scaffold-config.sh`, `scripts/migrate-consumer-tier1.sh`, and `lib/test/pin-corpus-lint.py`), while `lib/resolve-state-dir.sh` and `lib/state_dir.py` deliberately mirror the `paths.state_dir` literals instead of reading them. The comment now says so.

Five sibling comments introduced or rewritten by the same change are corrected alongside it: `scripts/scaffold-config.sh` attributed the config-key migration's skip conditions to an unusable `jq` when they are an absent rename map or a missing `python3` (and the anti-graft guard cannot cover the `jq` path at all, because an unusable `jq` skips the whole backfill); `scripts/migrate-consumer-tier1.sh` cited a deleted identifier as the case its key-rule lookahead rejects, and credited the lookbehind with protecting two frozen shapes that no rewrite rule can match in the first place; `install.sh` named the pre-rename config key in a comment whose scanner probes both spellings, left the same scanner's malformed-shape enumeration naming only the superseded block, and — after the mechanical path swap — illustrated a `devflow` substring hazard with an example string that no longer contains that substring; and `lib/test/pin-corpus-lint.py` documented a `None` return on a helper that only ever raises.

Comment-only: no executable behaviour, machine-consumed contract, or test assertion changes.
