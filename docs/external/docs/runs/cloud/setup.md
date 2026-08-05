---
title: "Cloud Setup"
description: "Configure cloud authentication, repository settings and runtime provisioning."
---

# Cloud Setup

This page is for repository maintainers who have installed PRFlow's cloud files and need to make the first run succeed.

## Add Model Authentication

The default Anthropic route needs one repository or environment secret:

```text
CLAUDE_CODE_OAUTH_TOKEN
```

Add it under **Settings → Secrets and variables → Actions → Secrets**. The built-in `GITHUB_TOKEN` handles GitHub operations and needs no setup.

A fully provider-routed installation can use `DEVFLOW_PROVIDER_API_KEY` instead of the OAuth token. Route every active section before removing `CLAUDE_CODE_OAUTH_TOKEN`. A partially routed installation may need both secrets because each section chooses its route independently. See [Providers](/docs/configuration/providers).

## Review Repository Configuration

The installer creates `.prflow/config.json`. Commit this file because the workflows read it from the repository.

At minimum, review:

- `base_branch` and `claude_model`.
- `prflow.allowed_users` and `prflow.allowed_bots`.
- The `setup` block for runtimes and install commands.
- `prflow.allowed_tools` and `prflow_implement.allowed_tools` for repository-specific commands.
- `workflows.prflow`, which enables the shipped command and implementation paths.

Running `/prflow:init` is recommended after installation or an upgrade. It backfills new settings without replacing existing values and detects common project tools.

## Provision the Runtime

PRFlow prepares the runner in this order:

1. Set up Python.
2. Set up Node.js.
3. Set up PHP.
4. Start configured service containers with Docker.
5. Run each `setup.install` line from the repository root.

Keep Python 3.11 or newer and PyYAML available even in non-Python projects because PRFlow's cloud helpers use them. Provisioning a command does not grant the agent permission to run it. Add the command to the correct allowlist separately. See [Runtime Setup](/docs/configuration/runtime-setup) and [Tool Permissions](/docs/configuration/tool-permissions).

## Optional GitHub App

The default path needs no GitHub App. Add one when cloud implementation must push changes under `.github/workflows/`, when you need a dedicated automation identity or when a configured stall backstop must post a workflow-triggering resume comment.

Configure the App with:

| **Kind** | **Name** |
| --- | --- |
| Repository or organization variable | `DEVFLOW_APP_ID` |
| Repository or organization secret | `DEVFLOW_APP_PRIVATE_KEY` |

Install the App on the repository with `Contents: write`, `Workflows: write`, `Pull requests: write`, `Issues: write` and `Actions: read`. A configured but invalid App fails at token creation. An unset App falls back to `GITHUB_TOKEN`.

## Run a Smoke Test

Open a throwaway pull request and add this standalone conversation comment:

```text
/prflow:review
```

Confirm that the workflow starts, provisions the environment and posts a result. For implementation, use a low-risk issue and follow [Cloud Triggers](/docs/runs/cloud/triggers).
