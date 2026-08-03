---
title: "Installation"
description: "Install the PRFlow Claude Code plugin and initialize a repository."
---

# Installation

## Requirements

Before installing PRFlow, make sure your development environment has:

- Claude Code
- Git
- GitHub CLI, authenticated with `gh auth login`
- `jq`
- Python 3.11 or newer

On Windows, run PRFlow from WSL, Git Bash or MSYS2 so a POSIX-compatible Bash shell is available.

## Install the plugin

Add the PRFlow marketplace, then install the plugin:

```bash
claude plugin marketplace add The01Geek/prflow
claude plugin install prflow@devflow-marketplace
```

The marketplace retains its original `devflow-marketplace` name. The plugin and its commands use the `prflow` name.

Restart Claude Code or run:

```text
/reload-plugins
```

## Initialize a repository

From the repository you want PRFlow to manage, run:

```text
/prflow:init
```

Initialization creates or updates the repository's PRFlow configuration while preserving existing values. You can now continue to your [first run](/docs/getting-started/first-run).

## Update later

Update the marketplace when you want to fetch a newer PRFlow release:

```text
/plugin marketplace update devflow-marketplace
```
