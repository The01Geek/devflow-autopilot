---
title: "Settings"
description: "Configure implementation, review, setup and documentation behavior."
---

# Settings

The `.prflow/config.json` file groups settings by workflow. Common areas include:

- `base_branch` for the branch pull requests target
- `prflow` for shared authorization, tool and workpad behavior
- `prflow_implement` for implementation effort, pull request state and allowed tools
- `prflow_review` for review thresholds, progress and agent overrides
- `prflow_review_and_fix` for fix thresholds and iteration limits
- `setup` for cloud runtimes and repository install commands
- `docs` for internal docs, public docs, release notes and changelog locations

Run `/prflow:init` after upgrading the plugin to backfill newly introduced keys while preserving values you already set.

Treat `.prflow/config.json` as code: review changes, keep allowed tools narrow and validate JSON before publishing it. Do not store API keys, tokens or private keys in this file.
