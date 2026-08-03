---
title: "Configuration"
description: "Adapt PRFlow to a repository without changing the plugin."
---

# Configuration

PRFlow stores repository-level behavior in `.prflow/config.json`. Running `/prflow:init` creates the file when it is absent and adds newly supported keys without replacing your existing values.

Use [Settings](/docs/configuration/settings) for execution, review, setup and documentation options. Use [Review agents](/docs/configuration/review-agents) when individual review passes need different model or reasoning settings.

Commit shared repository configuration when the whole team should use it. Keep credentials in your platform's secret store, never in the PRFlow configuration file.
