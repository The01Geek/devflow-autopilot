---
bump: patch
type: Fixed
---

- **Make selectable test-module runs clean up reliably when interrupted.** On POSIX hosts with signal and process-group support, both focused and full-suite boundaries now supervise, forward, boundedly escalate, and reap HUP, INT, and TERM across the module process group, while the boundary fallback removes owned scratch artifacts for every selectable module; an explicitly reported host-capability skip covers unsupported hosts, and the signal matrix covers parent-only, module-only, and process-group delivery. (#592)
