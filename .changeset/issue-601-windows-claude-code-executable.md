---
bump: minor
type: Added
---

- **Self-hosted Windows runner support via `setup.claude_code_executable`.** All three cloud
  workflows that invoke `anthropics/claude-code-action` (`devflow.yml`, `devflow-implement.yml`,
  `devflow-runner.yml`) now pass the action's `path_to_claude_code_executable` input, sourced
  from a new optional config key `setup.claude_code_executable`. Set it (typically on a
  self-hosted Windows runner, whose OS the action's Unix-only bundled installer cannot serve) to
  the path of a pre-installed Claude Code executable and the action skips installation and uses
  it; unset or empty (the default, and every Linux consumer) resolves the input to an empty
  string and leaves the action's automatic-install path unchanged. `devflow-runner.yml` reads the
  key only from the trusted base-ref config, never a PR-head config, because that write-token job
  executes the resolved path. The key is trigger-time-resolved, so its effect is post-merge-only.
  A value that is set but unusable — a non-string leaf, a string with an embedded newline/CR, or
  a whitespace-only string — is rejected to empty (auto-install) and emits a workflow
  `::warning::` naming the key, so a mistyped path does not silently revert to the Windows-fatal
  installer path. (#604)
