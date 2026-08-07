---
title: "Local Runs"
description: "Run PRFlow interactively from a supported coding client."
---

Run PRFlow directly from Claude Code, GitHub Copilot CLI or Codex CLI. Local runs are the fastest way to start and require no GitHub Actions workflow or cloud secret.

Open your coding client anywhere inside the target Git repository, then enter a namespaced command. For example, the implementation command is `/prflow:implement 123` in Claude Code, `/prflow/implement 123` in GitHub Copilot CLI and `$prflow:implement 123` in Codex CLI.

The run uses:

- The repository and Git root discovered from the current directory.
- Your authenticated GitHub CLI identity.
- The tests, linters and development tools available on the machine.
- The coding client's permission system and current interaction.
- Built-in configuration defaults, with `.prflow/config.json` overrides when present.

Repository initialization is recommended for customization, but it is not required.

## When to Run Locally

Use a local run when you want to:

- Answer clarification questions while work proceeds.
- Review tool requests before granting them.
- Use services or development tools already configured on the workstation.
- Create issues, configure PRFlow, update documentation or run retrospectives.
- Inspect a run closely before enabling cloud automation.

## Next Steps

- Check the complete [client syntax and local-only command guidance](/docs/runs/local/client-commands).
- Review [local permission boundaries](/docs/runs/local/permissions).
- Understand [working-directory and Git-root behavior](/docs/runs/local/working-directory).
