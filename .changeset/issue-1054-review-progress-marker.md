---
bump: patch
type: Fixed
---

- **Keep seeded, interrupted cloud reviews discoverable.** When the cloud seed helper runs, it now derives and writes the workflow-run marker so dead-run cleanup can find and flip that comment. A run that never reaches the helper remains a separate omission mode. (#1093)
