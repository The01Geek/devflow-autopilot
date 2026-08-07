---
bump: patch
---

Add the macOS Bash 3.2 portability lane's foundation: a versioned shell-surface registry classifying every tracked shipped shell entry point as `portable` or `excluded`, an independent totality checker that reconciles it against the git index, a shallow-safe pull-request classifier that selects the surface to verify (and falls back to the complete portable population on any input it cannot establish), an executable Bash-3.2 construct-fixture corpus, and a Python process-group supervisor that runs it under a per-fixture watchdog without GNU `timeout`. CI gains a macOS producer job and an always-running aggregator publishing the stable check `portability / macOS Bash 3.2`, which the auto-review notification now waits on without being suppressed by it.

The lane's first run found and this change fixes a real incompatibility: `scripts/render-grounding-block.sh` nested a quoted heredoc inside a command substitution, which stock macOS `/bin/bash` refuses to parse.
