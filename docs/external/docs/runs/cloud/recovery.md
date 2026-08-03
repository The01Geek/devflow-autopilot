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

For symptom-specific checks, see [Troubleshooting cloud runs](/docs/troubleshooting/cloud-runs).
