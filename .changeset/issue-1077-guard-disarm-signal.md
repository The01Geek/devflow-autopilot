---
bump: patch
type: Fixed
---

- **The PreToolUse shape guard now publishes a distinguishing signal when it disarms.** When
  `scripts/pretooluse-shape-guard.py` cannot load or exercise its classifier
  (`lib/test/extract-command-shapes.py`), it still fails open to `defer` and exit 0 — the
  deliberate fail-open contract is unchanged — but it now writes a `pretooluse-guard-disarmed`
  marker on the same path as the heartbeat, so a disarmed run is no longer byte-identical (on
  every published artifact) to one that fired and matched nothing. The marker's cause is keyed
  on the exception actually raised (`FileNotFoundError` from `exec_module`, not the unreachable
  `ImportError` branch) and names the workspace-relative path with no `lib/test` as the cause,
  not the vendor slice's prune. (#1077)
