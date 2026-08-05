---
title: "Installation"
description: "Install the PRFlow plugin in Claude Code, GitHub Copilot CLI or Codex CLI."
---

# Installation

This page is for developers installing the local PRFlow plugin. Plugin installation makes the skills available in your coding client. Repository initialization is a separate, recommended step.

The plugin is named `prflow`. Its marketplace intentionally keeps the `devflow-marketplace` name. PRFlow has no companion-plugin dependencies.

If you previously installed DevFlow, follow [Migrate From DevFlow](/docs/getting-started/migrate-from-devflow) instead.

## Claude Code

Add the marketplace, then install PRFlow:

```bash
claude plugin marketplace add The01Geek/prflow
claude plugin install prflow@devflow-marketplace
```

The interactive `/plugin` manager provides equivalent marketplace and installation actions. Start a new Claude Code session if the PRFlow skills do not appear immediately.

## GitHub Copilot CLI

Add the marketplace, then install PRFlow:

```bash
copilot plugin marketplace add The01Geek/prflow
copilot plugin install prflow@devflow-marketplace
```

Start a new GitHub Copilot CLI session after installation.

## Codex CLI

Add the marketplace, then install PRFlow:

```bash
codex plugin marketplace add The01Geek/prflow
codex plugin add prflow@devflow-marketplace
```

Start a new Codex CLI session after installation.

## Continue Setup

Plugin installation does not create repository configuration or install system packages. Before the first run:

1. Confirm the [local requirements](/docs/getting-started/requirements).
2. Run [initialization](/docs/getting-started/initialization) if you want a configurable repository scaffold and detected tools.
3. Follow the [first-run guide](/docs/getting-started/first-run).

See [Updates](/docs/getting-started/updates) when you need a newer plugin release.
