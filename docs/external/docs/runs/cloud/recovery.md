---
title: "Cloud recovery"
description: "Diagnose and safely resume a failed, stalled or interrupted cloud run."
---

# Cloud Recovery

Start with the PRFlow workpad comment and the linked GitHub Actions run. They show the last completed phase and the command that failed.

## Common recovery sequence

1. Confirm the original commenter is still authorized.
2. Check that required secrets and workflow permissions are available.
3. Inspect setup output for missing runtimes, packages or repository install commands.
4. Confirm the failing verification command is allowed for that workflow.
5. Fix the underlying configuration or repository problem, then trigger a new run.

Do not repeatedly retrigger an unchanged failure. A new run should follow a concrete correction or a known transient service interruption.

A run that is interrupted while it is writing code commits and pushes the files it has produced at each of its internal checkpoints, so a re-triggered run adopts the same branch and resumes from what already landed rather than starting the implementation over. This is designed to bound loss to roughly the most recent ten minutes of edits rather than the whole attempt — a design target, not a guarantee. Work produced since the last checkpoint is still lost, and a run interrupted before it reaches its first checkpoint leaves nothing behind.

For symptom-specific checks, see [Troubleshooting cloud runs](/docs/troubleshooting/cloud-runs).
