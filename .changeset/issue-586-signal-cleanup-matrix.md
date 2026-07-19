---
bump: patch
type: Fixed
---

- **Make selectable test-module runs clean up reliably when interrupted.** Both focused and full-suite boundaries now supervise, forward, boundedly escalate, and reap HUP, INT, and TERM across the module process group, while the create-issue contract module and its boundary fallback remove owned scratch artifacts; a signal matrix covers parent-only, module-only, and process-group delivery. (#592)
