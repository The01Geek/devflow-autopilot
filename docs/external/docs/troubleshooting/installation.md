---
title: "Installation problems"
description: "Fix common PRFlow marketplace, dependency and plugin-loading failures."
---

# Installation Problems

## Commands do not appear

Restart Claude Code or run `/reload-plugins`. Confirm that the plugin is installed from `prflow@devflow-marketplace`; the marketplace name intentionally differs from the plugin name.

## Marketplace content is stale

Refresh it explicitly:

```text
/plugin marketplace update devflow-marketplace
```

Then restart Claude Code or reload plugins.

## A prerequisite is missing

Verify `git`, `gh`, `jq` and Python 3.11 or newer are available on your path. Authenticate GitHub CLI with:

```bash
gh auth login
```

If YAML support is missing from Python, install PyYAML in the active environment:

```bash
python3 -m pip install PyYAML
```

Windows users should run from WSL, Git Bash or MSYS2.
