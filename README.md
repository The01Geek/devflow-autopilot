# devflow-autopilot

Agent coding and workflow automation template files. Use this template to bootstrap GitHub Projects automation and Claude Code agents/skills for any project.

---

## What's Included

### Workflows

| File | Description |
|------|-------------|
| claude.yml | Claude Code action — responds to @claude mentions in issues/PRs |
| WikiWizard.yml | Auto-generate internal, external docs and release notes on PR merge |
| close-released-items.yml | Bulk close "Released" items in GitHub Projects |
| comment-on-draft-issues.yml | Auto-comment /implement on draft issues |
| move-to-in-progress.yml | Move issue to "In Progress" on branch creation |
| sync-pr-status-to-issue.yml | Sync PR project status to linked issues |
| update-ticket-status.yml | Manual bulk status update via workflow dispatch |

### Agents

| File | Description |
|------|-------------|
| code-quality-reviewer | Language-agnostic code quality review |
| documentation-accuracy-reviewer | Verifies documentation accuracy |
| github-issue-creator | Creates structured GitHub issues from rough requirements |
| performance-reviewer | Performance bottleneck analysis |
| security-code-reviewer | OWASP-based security review |
| test-coverage-reviewer | Test coverage gap analysis |
| wikiwizard-combined | Orchestrates documentation generation |

### Skills

| File | Description |
|------|-------------|
| add-ticket | Creates GitHub issues from user stories |
| documentation-review | Reviews and updates internal docs |
| implement | Full feature development orchestrator |
| verify-doc | Verifies/creates documentation for topics |

---

## Quick Start

1. Click "Use this template" → "Create a new repository"
2. Edit `.github/project-config.yml` with your project values
3. Set up authentication (see below)
4. Enable/disable workflows via the `workflows:` toggles in config

---

## Configuration Reference

All configuration lives in `.github/project-config.yml`.

| Field | Description | Default |
|-------|-------------|---------|
| project_number | GitHub Project board number | "1" |
| base_branch | Default PR target branch | "main" |
| claude_model | Claude model for AI workflows | "claude-sonnet-4-6" |
| statuses.draft | Draft status name | "Draft" |
| statuses.in_progress | In Progress status name | "In Progress" |
| statuses.ai_pr_drafted | AI PR Drafted status name | "AI PR Drafted" |
| statuses.released | Released status name | "Released" |
| statuses.closed | Closed status name | "Closed" |
| docs.internal | Internal docs path | "docs/internal/" |
| docs.external | External docs path | "docs/external/" |
| bot_login | Bot account login | "" (empty) |
| claude.allowed_bots | Bots allowed to trigger Claude action | "" (empty) |
| wikiwizard.documented_label | Label applied after docs generated | "Documented" |
| wikiwizard.release_notes_file | Release notes file path | "docs/external/release-notes.md" |
| workflows.claude | Enable/disable claude.yml | true |
| workflows.claude-weekly-scan | Enable/disable claude-weekly-scan.yml | true |
| workflows.WikiWizard | Enable/disable WikiWizard.yml | true |
| workflows.close-released-items | Enable/disable close-released-items.yml | true |
| workflows.comment-on-draft-issues | Enable/disable comment-on-draft-issues.yml | true |
| workflows.move-to-in-progress | Enable/disable move-to-in-progress.yml | true |
| workflows.sync-pr-status-to-issue | Enable/disable sync-pr-status-to-issue.yml | true |
| workflows.update-ticket-status | Enable/disable update-ticket-status.yml | true |

---

## Authentication Setup

### Required Secrets

| Secret | Description |
|--------|-------------|
| `CLAUDE_CODE_OAUTH_TOKEN` | For Claude Code API |
| `APP_ID` | GitHub App numeric ID |
| `APP_PRIVATE_KEY` | GitHub App PEM private key |

### GitHub App Setup

1. Go to Settings > Developer settings > GitHub Apps
2. Create app with permissions: issues (write), pull_requests (write), projects (read/write), contents (read)
3. Install on your repo
4. Add `APP_ID` and `APP_PRIVATE_KEY` to repo secrets

### PAT Alternative

Use a Personal Access Token with `project` scope instead. Modify workflows to use the PAT secret directly.

---

## Cross-Workflow Dependencies

- WikiWizard's `request-claude-review` job posts a comment as the bot to trigger `claude.yml`
- For this to work: the bot login from your GitHub App must match `claude.allowed_bots` in config
- If you don't use a bot, set `bot_login` to empty and this job is skipped automatically

---

## Customization

- **Disable any workflow**: set its toggle to `false` in `.github/project-config.yml`
- **Add project-specific skills**: create new directories under `.claude/skills/`
- **Add project-specific agents**: add `.md` files to `.claude/agents/`
- **Add language-specific plugins**: edit `.claude/settings.json`
- **Add project conventions**: create a `CLAUDE.md` with your project's standards and architecture notes

---

## Examples

The `examples/` directory contains reference files not used by the template directly:

- `post-review-comment.yml` — Example workflow for triggering Claude on PR review completion
- `documentation-generator.action.prompt.md` — Example prompt for documentation generation agents (ADR/Zangerine-specific; use as a reference for writing your own)

---

## License

MIT
