---
bump: patch
---

### Added

- Selectable test modules for fast local iteration (PR #563): a registry-driven
  focused runner (`lib/test/run-module.sh`, backed by `test_modules` in
  `scripts/workflow-flight-recorder-registry.json`) and a fail-closed full-suite
  boundary (`lib/test/module-harness.sh`) around sourceable modules under
  `lib/test/modules/`, starting with the extracted workflow-flight-recorder
  block. Selection and whole-registry validation finish before any module body
  is sourced; unknown or invalid selections fail closed pre-source, an executed
  module below its assertion floor fails the run afterward, and each
  module's assertions ride a private tally so an over-broad module write cannot
  erase an earlier suite verdict. The implement and review-and-fix prompt
  extensions steer RED/GREEN iteration to the focused runner while keeping the
  complete suite plus lint gates as the only completion gate.
