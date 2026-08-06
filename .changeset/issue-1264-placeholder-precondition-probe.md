---
bump: patch
---

### Added

- A maintainer-dispatched `matcher-probe.yml` arm measuring whether `claude-code-action`
  substitutes a render-time `` !`<command>` `` placeholder in a plugin-sourced `SKILL.md`
  reached by a slash-command prompt, whether the injected command sees
  `DEVFLOW_PROMPT_EXTENSION_ROOT`, and whether rendering is gated by `--allowed-tools`.
  This discharges issue #1264's precondition, whose outcome routes that issue between
  render-time injection and workflow-side prompt composition. The probe carries its own
  throwaway marketplace under `.github/probe-plugin/`, which no consumer receives, and its
  verdict is derived deterministically by `scripts/placeholder-probe-verdict.py`.
