# devflow-autopilot

Agent coding and workflow automation template for GitHub Projects + Claude Code. Use this template to bootstrap AI-powered development workflows, automated code review, documentation generation, and project management for any repository.

---

## Prerequisites

### GitHub Projects Board

Several workflows depend on a [GitHub Projects (v2)](https://docs.github.com/en/issues/planning-and-tracking-with-projects) board. Before enabling workflows:

1. Create a GitHub Project board linked to your repository
2. Add a **Status** field with values matching your config (default: Draft, In Progress, AI PR Drafted, Released, Closed)
3. Set the `project_number` in `.github/project-config.yml` to your board's number (from the project URL)

If you don't use GitHub Projects, disable the project-dependent workflows (`comment-on-draft-issues`, `move-to-in-progress`, `sync-pr-status-to-issue`, `close-released-items`) in config.

---

## What's Included

### Workflows

| File | Description |
|------|-------------|
| claude.yml | Claude Code action — responds to @claude mentions in issues/PRs |
| WikiWizard.yml | Auto-generate internal, external docs and release notes during PR review |
| close-released-items.yml | Bulk close "Released" items in GitHub Projects |
| comment-on-draft-issues.yml | Auto-comment /implement on draft issues |
| move-to-in-progress.yml | Move issue to "In Progress" on branch creation |
| sync-pr-status-to-issue.yml | Sync PR project status to linked issues |

### Agents

| File | Description |
|------|-------------|
| checklist-generator | Enumerates verifiable claims in code diffs for review |
| checklist-verifier | Verifies single checklist claims against source code |
| code-quality-reviewer | Language-agnostic code quality review |
| documentation-accuracy-reviewer | Verifies documentation accuracy |
| github-issue-creator | Creates structured GitHub issues from rough requirements |
| performance-reviewer | Performance bottleneck analysis |
| security-code-reviewer | OWASP-based security review |
| test-coverage-reviewer | Test coverage gap analysis |
| wikiwizard-combined | Orchestrates documentation generation |

### Skills

| Skill | Description |
|-------|-------------|
| /add-ticket | Creates GitHub issues from user stories with optional clarification |
| /documentation-review | Reviews and updates internal docs to match code changes |
| /implement | Full feature development orchestrator (issue to PR) |
| /review | Four-phase PR review engine with verification checklist |
| /review-and-fix | Review + automatic fix loop (max 4 iterations) |
| /verify-doc | Verifies/creates documentation for a specific topic |

---

## Quick Start

1. Click "Use this template" > "Create a new repository"
2. Edit `.github/project-config.yml` with your project values
3. Set up authentication (see below)
4. Set up a GitHub Projects board (see Prerequisites)
5. Customize `CLAUDE.md` with your project's conventions and architecture
6. Enable/disable workflows via the `workflows:` toggles in config

---

## Configuration Reference

All configuration lives in `.github/project-config.yml`.

| Field | Description | Default |
|-------|-------------|---------|
| project_number | GitHub Project board number | "1" |
| base_branch | Default PR target branch | "main" |
| claude_model | Claude model for AI workflows | "claude-opus-4-6" |
| statuses.draft | Draft status name | "Draft" |
| statuses.in_progress | In Progress status name | "In Progress" |
| statuses.ai_pr_drafted | AI PR Drafted status name | "AI PR Drafted" |
| statuses.released | Released status name | "Released" |
| statuses.closed | Closed status name | "Closed" |
| docs.internal | Internal docs path | "docs/internal/" |
| docs.external | External docs path | "docs/external/" |
| bot_login | Bot account login | "" (empty) |
| claude.allowed_bots | Bots allowed to trigger Claude action | "" (empty) |
| test_command | Test command(s) for review-and-fix to run | (echo placeholder) |
| wikiwizard.documented_label | Label applied after docs generated | "Documented" |
| wikiwizard.release_notes_file | Release notes file path | "docs/external/release-notes.md" |
| workflows.* | Enable/disable individual workflows | true |

---

## Authentication Setup

### Required Secrets

| Secret | Description |
|--------|-------------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth token ([docs](https://docs.anthropic.com/en/docs/claude-code/github-actions)) |
| `BOT_APP_ID` | GitHub App numeric ID (for project automation) |
| `BOT_PRIVATE_KEY` | GitHub App PEM private key |

### GitHub App Setup

1. Go to Settings > Developer settings > GitHub Apps
2. Create app with permissions: issues (write), pull_requests (write), projects (read/write), contents (read)
3. Install on your repo
4. Add `BOT_APP_ID` and `BOT_PRIVATE_KEY` to repo secrets

### PAT Alternative

Use a Personal Access Token with `project` scope instead. Modify workflows to use the PAT secret directly.

---

## How It Works

### Workflow Pipeline

```
Issue created (Draft status)
  -> comment-on-draft-issues.yml posts "@claude /implement #N"
  -> claude.yml runs /implement skill
     -> Creates branch, implements feature, opens PR

Branch created (issue-123-*)
  -> move-to-in-progress.yml updates issue status

PR opened/updated
  -> WikiWizard.yml generates docs on PR branch
  -> sync-pr-status-to-issue.yml syncs status to linked issues

PR merged
  -> close-released-items.yml (manual) archives completed items
```

### Cross-Workflow Dependencies

- WikiWizard's `request-claude-review` job posts a comment as the bot to trigger `claude.yml`
- For this to work: the bot login from your GitHub App must match `claude.allowed_bots` in config
- If you don't use a bot, set `bot_login` to empty and this job is skipped automatically

---

## Customization

- **Disable any workflow**: set its toggle to `false` in `.github/project-config.yml`
- **Configure test commands**: set `test_command` in config so `/review-and-fix` runs your test suite
- **Add project-specific skills**: create new directories under `.claude/skills/`
- **Add project-specific agents**: add `.md` files to `.claude/agents/`
- **Add language-specific plugins**: edit `.claude/settings.json`
- **Add project conventions**: fill in `CLAUDE.md` with your project's standards and architecture

---

## Examples

The `examples/` directory contains reference files not used by the template directly:

- `post-review-comment.yml` — Example workflow for triggering Claude on PR review completion
- `documentation-generator.action.prompt.md` — Example prompt for documentation generation agents

---

## License

MIT
