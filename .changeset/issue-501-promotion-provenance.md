---
bump: patch
type: Fixed
---

- **Gate shadow synthesis on promotion provenance.** Distinguish shadow-driven, post-shadow park-calibration, pre-shadow park-calibration, and unestablished promotion records so telemetry recovers genuine drops without fabricating shadow attribution or warning on legitimate pre-shadow promotions. (#508)
