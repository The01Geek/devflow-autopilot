# CLAUDE.md

## Project Overview

**devflow-autopilot** is a GitHub template repository that wires Claude Code into GitHub workflows for automated issue-to-PR pipelines. It is **not an application** — it contains no backend, frontend, or runtime code. The entire project is GitHub Actions workflows, Claude Code skills/agents, and configuration.

**Repository**: https://github.com/The01Geek/devflow-autopilot
**Primary Branch**: `main`

## What This Repo Contains

```
.github/
  workflows/           # GitHub Actions workflow YAML files (the core of the project)
  project-config.yml   # Central config: project number, statuses, toggles, model, docs paths
.claude/
  skills/              # Slash command skill definitions (implement, review, docs, etc.)
  agents/              # Specialized agent definitions (checklist, issue creator)
  settings.json        # Claude Code plugin/tool settings
docs/
  internal/            # AI-generated technical docs (for developers and future AI context)
  external/            # AI-generated customer-facing docs
CLAUDE.md              # This file — project conventions for Claude Code
```

There is no `src/`, no `package.json`, no `requirements.txt`, no Docker, no database.

## Configuration

All workflow behavior is controlled by `.github/project-config.yml`. Key fields:
- `project_number` — GitHub Projects (v2) board number
- `base_branch` — default PR target (`main` for consuming repos)
- `claude_model` — model used by AI workflows
- `statuses.*` — must match GitHub Project board status names exactly
- `workflows.*` — per-workflow enable/disable toggles

## Workflows

| File | Trigger | Purpose |
|------|---------|---------|
| `claude.yml` | `@claude` mention | Runs Claude Code with full skill/agent access |
| `WikiWizard.yml` | PR opened/updated | Auto-generates internal docs, external docs, release notes |
| `comment-on-draft-issues.yml` | Issue created | Triggers `/implement` on Draft issues |
| `move-to-in-progress.yml` | Branch created | Updates project board status |
| `sync-pr-status-to-issue.yml` | PR state change | Syncs PR status to linked issues |
| `close-released-items.yml` | Manual dispatch | Moves "Released" items to "Closed", optionally archives |

## GitHub App

Project automation uses the **Radman AI** GitHub App: https://github.com/apps/radman-ai

Users can install it directly, or create their own GitHub App if they prefer custom branding/permissions.

## Required Secrets

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code API access |
| `RADMAN_AI_PRIVATE_KEY` | GitHub App private key (Radman AI or your own app) |

The GitHub App ID is read from `app_id` in `project-config.yml` (defaults to `3102164` for Radman AI).

## Coding Standards

Since this project is purely YAML workflows and Markdown skills:

- **Workflow YAML**: Keep steps focused and well-commented. Use `project-config.yml` for all configurable values — never hardcode project numbers, status names, or bot logins in workflow files.
- **Skills/Agents**: Follow the existing `SKILL.md` format. Each skill is self-contained with clear instructions.
- **Action versions**: Keep GitHub Actions pinned to latest major versions that support Node.js 24+ to avoid deprecation warnings.
