---
bump: patch
type: Fixed
---

- **`extract-doc-needed-paths.sh`: handle two adjacent Documentation Needed grammar shapes.** A top-level bold deliverable list after the bullet (`- **`docs/a.md`**`) is now captured instead of the first item silently closing the scope to empty output (Shape 1, a fail-open that disabled the Phase 4.1 gate), and a trailing blank-separated plain-prose paragraph no longer leaks its path-like tokens as deliverables (Shape 2, over-emission). A non-backticked bold item (`- **docs/a.md**`) remains indistinguishable from a peer label and is a pinned, documented drop; blank-separated plain sub-lists stay in scope. Adds a `run.sh` shape-matrix over both bullet forms × the follower shapes. (#327)
