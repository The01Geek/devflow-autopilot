---
title: "Installation"
description: "Install the PRFlow plugin and initialize a repository."
---

# Installation

## What You Need

To get started, you only need a supported coding agent:

- Claude Code
- GitHub Copilot
- Codex

PRFlow also uses Git, GitHub CLI, `jq`, Python 3.11 or newer and a POSIX-compatible Bash shell. You do not need to install all of these before installing the plugin. When you run PRFlow's `init` skill, it checks your environment, identifies anything that is missing and works with you through the required setup.

On Windows, PRFlow can guide you through using WSL, Git Bash or MSYS2 when a POSIX-compatible Bash shell is not already available.

## Install the Plugin

Choose the instructions for your coding agent. The marketplace retains its original `devflow-marketplace` name, while the plugin and its skills use the `prflow` name.

Already using the former DevFlow plugin? Follow [Migrate from DevFlow](/docs/getting-started/migrate-from-devflow) instead of reinstalling from scratch.

### Claude Code

Add the PRFlow marketplace, then install the plugin:

```bash
claude plugin marketplace add The01Geek/prflow
claude plugin install prflow@devflow-marketplace
```

Restart Claude Code or run:

```text
/reload-plugins
```

### GitHub Copilot CLI

Add the marketplace, install PRFlow and start a new Copilot CLI session:

```bash
copilot plugin marketplace add The01Geek/prflow
copilot plugin install prflow@devflow-marketplace
```

### Codex CLI

Add the marketplace, install PRFlow and start a new Codex CLI session:

```bash
codex plugin marketplace add The01Geek/prflow
codex plugin add prflow@devflow-marketplace
```

Codex plugins are available in Codex CLI and Codex in the ChatGPT desktop app. Availability on other Codex surfaces can depend on your Codex version and workspace policy.

## Initialize a Repository

From the repository you want PRFlow to manage, invoke `init` with the spelling used by your client.

**Claude Code:**

```text
/prflow:init
```

**GitHub Copilot CLI:**

```text
/prflow/init
```

**Codex:**

```text
$prflow:init
```

Follow the agent's instructions after invoking `init`. The agent checks your environment, guides you through missing requirements and creates or updates the repository's PRFlow configuration while preserving existing values. You can then continue to your [first run](/docs/getting-started/first-run).

## Update Later

Refresh the marketplace with the command for your client when you want to fetch a newer PRFlow release.

**Claude Code:**

```text
/plugin marketplace update devflow-marketplace
```

**GitHub Copilot CLI:**

```bash
copilot plugin marketplace update devflow-marketplace
```

**Codex CLI:**

```bash
codex plugin marketplace upgrade devflow-marketplace
```
