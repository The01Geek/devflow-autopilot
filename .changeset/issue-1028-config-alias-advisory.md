---
bump: patch
type: Added
---

- **The config-scaffolder now reports that leftover `devflow` spellings in your `config.json` are deliberate aliases.** After a migration or re-scaffold, `scripts/scaffold-config.sh` emits a one-time, report-only advisory (via the new `lib/generate-config-alias-advisory.py`) naming the accepted-alias categories your config actually still carries — the `agent_overrides` `devflow:` namespace, a `devflow`-spelled workpad marker, and `DevFlow` provenance label values — and states that they require no action. It also warns that the frozen `DEVFLOW_*` environment identifiers must never be hand-renamed, pointing at the existing freeze inventory rather than restating it. The advisory is derived from what your config contains (silent when nothing is superseded), never modifies any value, and reaches both `install.sh --apply` and `/prflow:init` because both call the one scaffolder. (#1028)
