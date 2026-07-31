---
bump: patch
---

Point runtime-visible messages at the resolving `/prflow:` commands, and correct two stale trigger-output-contract statements (#992, PR #1001).

Several runtime-visible messages still told users to run `/devflow:` commands that no longer resolve now that the plugin is named `prflow`. Renamed the dead references in the installer's superseded-identifier NOTICEs and their no-python3 warning arms, the shipped `marketplace.json` plugin `description`, the `provision-local-settings.sh` / `provision-auto-mode.sh` remedy messages, and the retrospective state-PR body (`lib/open-state-pr.sh`) to their `/prflow:` forms. Corrected the output-contract statements in `scripts/resolve-command-trigger.sh` and `skills/review/SKILL.md` to name the canonical `/prflow:<cmd>` token the detector actually emits.

This is the separable "dead commands" slice of #992; the Tier 1 directory/vendored-path/config-key/workflow-body migration, the Tier 2 label/telemetry-branch/marker rulings, and the Tier 3 environment-variable advisory report are deferred to follow-up issues.
