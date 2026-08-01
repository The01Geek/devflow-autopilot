---
bump: patch
type: Fixed
---

- **Keep interrupted cloud reviews discoverable.** Review-progress comments now use the workflow run marker derived by the seed helper, so dead-run cleanup can find and flip the correct comment. (#1093)
