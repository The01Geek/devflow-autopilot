---
bump: patch
---

- **Added the macOS Bash 3.2 portability lane's foundation.** CI gains a macOS producer job and an always-running aggregator publishing the stable check `portability / macOS Bash 3.2`, which the auto-review notification now waits on without being suppressed by it — a failing lane still dispatches the review. (#1394)
- **Added a versioned shell-surface registry and its independent totality checker.** `lib/shell-surface-registry.json` classifies every tracked shipped shell entry point as `portable` or `excluded`, and `lib/test/check-shell-surface-totality.py` derives the population from the git index rather than the registry, so an unclassified, stale, duplicated or glob-shaped entry fails the suite. (#1394)
- **Added a shallow-safe pull-request classifier and a process-group fixture supervisor.** The classifier selects the surface to verify from the paginated pull-request files API and falls back to the complete portable population on any input it cannot establish; the supervisor runs the Bash-3.2 construct-fixture corpus under a per-fixture watchdog without GNU `timeout`. (#1394)
- **Fixed a real macOS incompatibility the lane found on its first run.** `scripts/render-grounding-block.sh` nested a quoted heredoc inside a command substitution, which stock macOS `/bin/bash` refuses to parse; the heredoc is now emitted from a function and the rendered output is byte-identical. (#1394)
