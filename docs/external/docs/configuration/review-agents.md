---
title: "Review Agents"
description: "Override model, effort and iteration participation for individual review agents."
---

# Review Agents

This page is for maintainers who have measured a reason to tune individual review passes. PRFlow can apply model overrides to each reviewer request. It accepts and resolves per-agent effort settings. The current client cannot apply a different effort value to each agent, so PRFlow reports that the reviewer inherited the session effort.

`prflow_review.agent_overrides` is an object. It accepts a `default` entry and these canonical agent keys:

- `prflow:checklist-generator`.
- `prflow:checklist-deduper`.
- `prflow:checklist-verifier`.
- `prflow:code-reviewer`.
- `prflow:silent-failure-hunter`.
- `prflow:comment-analyzer`.
- `prflow:type-design-analyzer`.
- `prflow:pr-test-analyzer`.
- `prflow:requesting-code-review`.

The transitional `devflow:` spelling of each key remains accepted for existing configuration. Use `prflow:` for new entries.

| **Nested setting** | **Type and accepted values** | **Fallback or scaffold** | **Tier and security note** | **Example** |
| --- | --- | --- | --- | --- |
| `model` | String model identifier | No override; global or session model applies | Shared review engine. The selected model is passed to that reviewer. | `"model": "claude-opus-5"` |
| `effort` | `low`, `medium`, `high`, `xhigh` or `max` | No override; session effort applies | Shared review engine. The current client cannot apply a different effort value to each agent. Invalid values warn and fall back to the session effort. | `"effort": "low"` |
| `iterations` | `first-only` | Absent means every applicable iteration | Review-and-fix. `first-only` removes that agent from later fix-loop iterations. | `"iterations": "first-only"` |

An agent-specific entry replaces the `default` entry for that agent; the default does not fill missing fields inside a specific entry. The default applies only when no specific entry exists.

## Valid Override Example

```json
{
  "prflow_review": {
    "agent_overrides": {
      "default": {
        "effort": "low"
      },
      "prflow:checklist-deduper": {
        "model": "claude-sonnet-5",
        "effort": "low"
      },
      "prflow:code-reviewer": {
        "model": "claude-opus-5",
        "effort": "low",
        "iterations": "first-only"
      }
    }
  }
}
```
