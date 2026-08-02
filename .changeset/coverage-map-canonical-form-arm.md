---
bump: patch
---

Detect ordering/formatting drift in `lib/test/modules/coverage-map.json`. `coverage_map_guard.py` gains arm 11, which asserts the map on disk is byte-identical to its canonical serialization — the same `_serialize_map` output `--fix` writes — so a non-canonical key order (e.g. from a merge-conflict resolution) fails at the point it is introduced instead of being silently folded into a later, unrelated `--fix`. An unreadable raw file is reported as an unestablished measurement, never a pass. `--fix` is correspondingly widened (a recorded scope decision) to re-canonicalize an order-only drifted map, so its remedy names an action that actually repairs the violation; the two measured `--fix` paths (no-op on a canonical file, additive-only on a real repair) are unchanged.
