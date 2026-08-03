---
title: "Cloud setup"
description: "Configure repository automation, credentials and tools for PRFlow cloud runs."
---

# Cloud Setup

Cloud runs execute inside GitHub Actions, so every dependency and permission must be explicit.

## Required credential

Add the Claude Code OAuth token expected by your PRFlow workflow as the repository secret:

```text
CLAUDE_CODE_OAUTH_TOKEN
```

If you select another supported provider, also configure the provider credential required by that integration.

## Repository setup

Use PRFlow's cloud installer from the source checkout to add the supported workflow files and configuration. Review the generated diff before publishing it, especially:

- Workflow permissions and event triggers
- Authorized GitHub users or bots
- Python and Node.js versions
- Repository-specific install commands
- Commands permitted during implementation and review

Verification commands must be available to every execution path that needs them. If a required command is not allowed, PRFlow blocks that verification instead of silently assuming CI will cover it.

An optional GitHub App can provide workflow-write permissions and a dedicated automation identity. It is not required for the basic comment-driven setup.
