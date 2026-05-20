# DevFlow Cloud Tier — GitHub Actions setup (optional)

The **local tier** (the skills you run inside Claude Code) needs none of this.
The **cloud tier** makes DevFlow run *autonomously* on your repository: Claude
responds to issue/PR events, `/devflow:review` runs as a required status check,
and project-board status syncs automatically. This guide sets that up.

> Everything here is optional. Skip it entirely and DevFlow still works as an
> in-editor toolkit.

## How the cloud tier finds DevFlow's scripts

The local skills locate their bundled helpers via `${CLAUDE_SKILL_DIR}`. The
GitHub Actions workflows, however, reference helper scripts at the **literal
path** `.claude/plugins/devflow/scripts/…`. So the cloud tier expects DevFlow to
be **vendored into your repository** at `.claude/plugins/devflow/`, served from a
local-path marketplace. Two ways to do that:

1. **Vendor (recommended for CI determinism).** Copy this plugin into your repo at
   `.claude/plugins/devflow/`, add a repo-root `.claude-plugin/marketplace.json`
   with a `directory` source, and enable it in `.claude/settings.json`:
   ```jsonc
   {
     "extraKnownMarketplaces": {
       "devflow-marketplace": { "source": { "source": "directory", "path": "." } }
     },
     "enabledPlugins": { "devflow@devflow-marketplace": true }
   }
   ```
2. **Git submodule / subtree** at `.claude/plugins/devflow/` pinned to a release tag.

Then copy the workflow files you want from this repo's `.github/workflows/` and the
composite actions from `.github/actions/` into your repo.

## Required secrets

Add these as repository (or environment) secrets under **Settings → Secrets and
variables → Actions**:

| Secret | Used for | Notes |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates the Claude Code action (`/implement`, `/review` runners) | From your Anthropic account. |
| `DEVFLOW_APP_ID` | GitHub App ID (or App Client ID) for project automation | See "GitHub App" below. |
| `DEVFLOW_APP_PRIVATE_KEY` | The GitHub App's private key (PEM) | Paste the full PEM contents. |
| `PROJECT_PAT` | Classic/fine-grained PAT with `project` scope, for board status sync | Only needed if you use a GitHub Project board. |
| `GITHUB_TOKEN` | (built in — no action needed) | Provided automatically to workflows. |

## GitHub App (for project automation)

The board-sync and draft-issue workflows authenticate as a GitHub App so their
actions are attributable to a bot identity and can write to Projects.

1. Create a GitHub App (org or personal): **Settings → Developer settings → GitHub
   Apps → New**. Grant: Repository **Contents** (RW), **Issues** (RW),
   **Pull requests** (RW), and organization/user **Projects** (RW) if using a board.
2. Generate a private key (downloads a `.pem`).
3. Install the App on your repository.
4. Put the App ID in `DEVFLOW_APP_ID` and the PEM in `DEVFLOW_APP_PRIVATE_KEY`.
5. Set `app_id` and `bot_login` in `.github/project-config.yml` accordingly.

The composite action `.github/actions/get-app-token` exchanges these for a
short-lived installation token.

## Project board (optional)

The `move-to-in-progress`, `sync-pr-status-to-issue`, and `close-released-items`
workflows update a GitHub Project board. To use them:

1. Create a Project board and note its number (from the URL).
2. Set `project_number` and the `statuses:` field values in
   `.github/project-config.yml` to **exactly** match your board's Status field
   options.
3. Provide `PROJECT_PAT`.

If you don't use a board, delete those three workflows and leave
`project_number` as the placeholder.

## Configure and enable

1. `cp .github/project-config.example.yml .github/project-config.yml` and fill in
   every `YOUR_*` placeholder. Commit it (it's gitignored by default — use
   `git add -f .github/project-config.yml`, since the cloud workflows must read it
   from the checked-out tree).
2. The `workflows:` block in that file toggles each workflow on/off.
3. Make `Devflow Review` a required status check (Settings → Branches → branch
   protection) once you've confirmed it runs.

## Workflow inventory

| Workflow | Purpose | Needs |
|---|---|---|
| `ci.yml` | Runs DevFlow's own test suite | — (this repo's CI) |
| `claude.yml`, `claude-implement.yml`, `claude-runner.yml` | Run Claude Code skills in response to comments/events | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-review.yml` | Auto-runs `/devflow:review` as a gate on PRs | `CLAUDE_CODE_OAUTH_TOKEN` |
| `comment-on-draft-issues.yml` | Bot comments on new draft issues | GitHub App secrets |
| `move-to-in-progress.yml`, `sync-pr-status-to-issue.yml`, `close-released-items.yml` | Project-board status automation | `PROJECT_PAT` + board |

## A note on validation

The cloud-tier workflows were validated in their original home repository. When
adopting them, run a low-stakes test (e.g. open a throwaway issue and `@claude`
it) before relying on the automation — the exact tool-permission model for
plugin-bundled scripts in CI depends on how you vendor the plugin and on your
Claude Code action version.
