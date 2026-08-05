---
title: "Settings"
description: "Find the focused reference for each PRFlow configuration family."
---

# Settings

This page is a map for maintainers editing `.prflow/config.json`. Each linked reference lists types, accepted values, fallbacks, execution scope, security notes and examples.

| **Configuration family** | **Reference** |
| --- | --- |
| `$schema`, `base_branch`, `claude_model`, `prflow_version`, authorization, workpad and workflow toggles | [Core Settings](/docs/configuration/core-settings) |
| `prflow_implement` and `verification_flight` | [Implementation](/docs/configuration/implementation) |
| `prflow_review`, `prflow_review_and_fix` and `receiving_review` | [Review](/docs/configuration/review) |
| `prflow_review.agent_overrides` | [Review Agents](/docs/configuration/review-agents) |
| `providers` and per-tier provider selection | [Providers](/docs/configuration/providers) |
| `setup` | [Runtime Setup](/docs/configuration/runtime-setup) |
| All `allowed_tools` settings | [Tool Permissions](/docs/configuration/tool-permissions) |
| `docs`, `deferred` and `prflow_retrospective` | [Documentation and Retrospectives](/docs/configuration/documentation-and-retrospectives) |
| Execution diagnostics, transcript artifacts, denial records and `telemetry` | [Observability and Privacy](/docs/configuration/observability-and-privacy) |

## Read Defaults Correctly

The scaffold and runtime fallback can differ. For example, the current scaffold writes `prflow.effort: "low"`, while an absent key falls back to `high`. The focused pages label both when they differ.

Unknown top-level keys are tolerated by the schema for forward compatibility. Nested objects with closed schemas can reject unknown entries in editor validation. Cloud config loading validates JSON syntax but does not automatically run a full JSON Schema validator.
