---
bump: patch
type: Fixed
---

- **The light command trigger gate no longer aborts silently when `sed` is absent.** `scripts/resolve-command-trigger.sh` derived its dispatch decision (`cmd` and `det_number`) from the standalone-command detector's output with `sed` under `set -euo pipefail`, so a missing `sed` aborted the resolver with no `should_run=` emission and no breadcrumb — a fail-open abort in a trigger gate. It now parses the detector's `key=value` lines with bash builtins only (a here-string `while`-read loop, `case`, and `${var#prefix}` stripping) and declines fail-closed with a distinct breadcrumb when the detector emits no `command=` line, mirroring the heavy-path fix in `resolve-implement-trigger.sh`. (#1060)
