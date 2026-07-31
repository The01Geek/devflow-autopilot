---
bump: patch
type: Changed
---

Demote PyYAML from a hard `lib/preflight.sh` stop to an advisory gap on the local user tier. A host with a working Python 3.11+ that lacks PyYAML now passes preflight (exit 0) with a distinct advisory final line naming the `pip install` remedy, instead of failing with a non-zero exit. `git`, `gh`, `jq` and `python3` remain hard stops, and PyYAML stays required for the test suite, CI, and the cloud tiers. `/prflow:init` relays the PyYAML remedy as a non-blocking note on that advisory outcome. This alters the documented local-tier install requirements. (#991)
