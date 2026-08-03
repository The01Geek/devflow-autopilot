---
title: "Review agents"
description: "Tune model, effort and iteration behavior for PRFlow review passes."
---

# Review Agents

Use `prflow_review.agent_overrides` when a review pass needs different settings from the repository default.

```json
{
  "prflow_review": {
    "agent_overrides": {
      "default": {
        "effort": "high"
      },
      "prflow:code-reviewer": {
        "model": "<supported-model-id>",
        "effort": "high",
        "iterations": "first-only"
      }
    }
  }
}
```

An override can set `model`, `effort` or `iterations`. Supported effort values are `low`, `medium`, `high`, `xhigh` and `max`. Use `first-only` for an agent that should run only during the first review iteration.

Start with a default and add per-agent overrides only when you have a measured reason. Available models and effective reasoning controls can depend on the current Claude Code environment.
