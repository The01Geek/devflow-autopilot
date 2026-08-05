---
title: "Configuration"
description: "Configure PRFlow by execution tier without editing the plugin."
---

# Configuration

This section is for maintainers adapting PRFlow to a repository. Shared settings live in `.prflow/config.json`; credentials stay in GitHub secrets or the local environment.

Running `/prflow:init` is recommended. It creates the file when absent and backfills newly scaffolded keys without replacing existing values or arrays. Local skills can use built-in defaults without a config file, but cloud workflows require the committed file.

## Configuration Layers

- [Settings](/docs/configuration/settings) maps each setting family to its focused reference.
- [Core Settings](/docs/configuration/core-settings) covers repository, model, authorization and workflow toggles.
- [Implementation](/docs/configuration/implementation) covers pull-request state, checkpoints, stalls and verification coordination.
- [Review](/docs/configuration/review) covers verdicts, fix routing and legacy automatic-review settings.
- [Review Agents](/docs/configuration/review-agents) covers per-agent model and effort overrides.
- [Providers](/docs/configuration/providers) covers optional cloud model routing.
- [Runtime Setup](/docs/configuration/runtime-setup) covers languages, services and install commands.
- [Tool Permissions](/docs/configuration/tool-permissions) covers independent command allowlists.
- [Documentation and Retrospectives](/docs/configuration/documentation-and-retrospectives) covers docs, deferrals and the weekly retrospective.
- [Observability and Privacy](/docs/configuration/observability-and-privacy) covers diagnostics, transcripts, denied commands and telemetry storage.

Treat configuration as code. Validate the JSON, review tool grants and install commands and commit changes through the same review process as workflow changes.
