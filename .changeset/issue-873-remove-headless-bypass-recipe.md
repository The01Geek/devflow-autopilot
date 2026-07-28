---
bump: patch
type: Removed
---

- **Removed the unattended/bypass-permissions recipe from the retrospective-weekly skill.**
  `skills/retrospective-weekly/SKILL.md` no longer ships the `## § Cron / headless variant`
  section, which recommended adding `--dangerously-skip-permissions` for a fully unattended
  run — the only place in the retrospective-weekly skill that recommended disabling Claude
  Code's permission system, contrary to DevFlow's consent-gated posture and Anthropic Software
  Directory Policy section 1.B. The `docs/DEVFLOW_SYSTEM_OVERVIEW.md` command-catalog cell for
  the loop is narrowed from `interactively / headless` to
  `interactively (no documented unattended recipe)`. The loop remains fully usable
  interactively; no behavior changes. (#875)
