---
title: "Client Command Syntax"
description: "Use the correct PRFlow command syntax in Claude Code, GitHub Copilot CLI and Codex CLI."
---

Run the same PRFlow workflows from Claude Code, GitHub Copilot CLI or Codex CLI by using each client's namespace syntax.

## Syntax Table

| **Client** | **Pattern** | **Implementation Example** |
| --- | --- | --- |
| Claude Code | `/prflow:<skill>` | `/prflow:implement 123` |
| GitHub Copilot CLI | `/prflow/<skill>` | `/prflow/implement 123` |
| Codex CLI | `$prflow:<skill>` | `$prflow:implement 123` |

Replace `<skill>` with names such as `create-issue`, `implement`, `review`, `review-and-fix`, `docs` or `init`.

## Always Use the Namespace

Command names such as `review` and `init` can collide with commands built into a coding client. Always include the `prflow` namespace. A bare client command can invoke a different tool with different behavior.

Local commands use only the current `prflow` namespace. The former `/devflow:*` namespace survives only as a compatibility alias for supported GitHub cloud comment triggers. Do not use it for local commands.

## Commands Available Locally

The installed plugin exposes its public workflows locally, including:

- `create-issue` and `implement` for issue-driven delivery.
- `review` and `review-and-fix` for assessment and correction.
- `pr-description` for pull-request descriptions.
- `docs` and the focused documentation commands.
- `retrospective-weekly` for the self-improvement loop.
- `init` for repository setup and refresh.

The public cloud path is narrower. Fresh cloud installations support comment-driven `implement` and authorized `review`. Run configuration, issue authoring, direct `review-and-fix`, pull-request description, documentation and retrospective workflows locally.

## Arguments Follow the Skill Name

Arguments keep the same meaning across clients. Only the prefix and separator change:

| **Action** | **Claude Code** | **GitHub Copilot CLI** | **Codex CLI** |
| --- | --- | --- | --- |
| Implement issue 123 | `/prflow:implement 123` | `/prflow/implement 123` | `$prflow:implement 123` |
| Review pull request 456 | `/prflow:review 456` | `/prflow/review 456` | `$prflow:review 456` |
| Initialize the repository | `/prflow:init` | `/prflow/init` | `$prflow:init` |

See the [Workflow Guides](/docs/workflows/index) for each command's inputs and outcomes.
