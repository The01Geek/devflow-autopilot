---
bump: patch
---

### Fixed

- Marketplace add/update failed for consumers on Windows. A tracked test fixture at
  `lib/test/fixtures/shipped-pruned-path/skills/nul.md` used `nul` — a Windows reserved
  device-name stem — which git refuses to check out on that platform
  (`error: invalid path '<path>'`). Because the plugin's marketplace `source` is `./`, the
  whole repository is the plugin, so the clone failed before any vendor-slice pruning could
  make `lib/test` irrelevant, and `claude plugin marketplace add`/`update` reported
  `Failed to add marketplace: invalid path …`. The fixture is now generated at test runtime
  instead of tracked, so no path with a reserved stem — and no NUL-byte content — remains in
  the index for that surface.
