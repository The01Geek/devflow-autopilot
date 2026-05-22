# DevFlow Cloud Tier — GitHub Actions setup (optional)

The **local tier** (the skills you run inside Claude Code) needs none of this.
The **cloud tier** makes DevFlow run *autonomously* on your repository: Claude
responds to issue/PR events, `/devflow:review` runs as a required status check,
and project-board status syncs automatically. This guide sets that up.

> Everything here is optional. Skip it entirely and DevFlow still works as an
> in-editor toolkit.

## Install (and update) the cloud tier

Run this from the root of your repository — it installs everything (vendored
plugin, workflows, composite actions, a `.devflow/config.json` scaffold) and is
**idempotent, so the same command updates** to the latest later:

```bash
curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/main/install.sh | bash
# pin a version instead of tracking main:
#   curl -fsSL .../install.sh | DEVFLOW_REF=v1.2.0 bash
```

Then review with `git diff`, fill in the `YOUR_*` placeholders in
`.devflow/config.json`, and commit.

### Why the plugin is vendored (not added as a github marketplace in CI)

The local skills locate their helpers via `${CLAUDE_SKILL_DIR}`, but in the
`claude-code-action` runner that variable is unset, the bash sandbox cannot read
`~/.claude` (where a marketplace plugin would install), and `$`-expansion in
commands is blocked. So the workflows reference helper scripts at the **literal
workspace path** `.claude/plugins/devflow/scripts/…`, which means the plugin must
be **vendored into the repo** at `.claude/plugins/devflow/`. `install.sh` does
this for you and re-vendors on each run.

> **Local editor use is different** — there, add this repo as a github marketplace
> with auto-update and you never copy files:
> ```jsonc
> // ~/.claude/settings.json (or project .claude/settings.json)
> {
>   "extraKnownMarketplaces": {
>     "devflow-marketplace": {
>       "source": { "source": "github", "repo": "The01Geek/devflow-autopilot" },
>       "autoUpdate": true
>     }
>   },
>   "enabledPlugins": { "devflow@devflow-marketplace": true }
> }
> ```

### Custom secret names

If your repo stores the App/PAT secrets under non-default names, add a
`cloud_secrets` block to `.devflow/config.json` (see the template) and
`install.sh` rewrites the workflows to your names on every run.

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
5. Set `app_id` and `bot_login` in `.devflow/config.json` accordingly.

The composite action `.github/actions/get-app-token` exchanges these for a
short-lived installation token.

## Project board (optional)

The `move-to-in-progress`, `sync-pr-status-to-issue`, and `close-released-items`
workflows update a GitHub Project board. To use them:

1. Create a Project board and note its number (from the URL).
2. Set `project_number` and the `statuses` field values in
   `.devflow/config.json` to **exactly** match your board's Status field
   options.
3. Provide `PROJECT_PAT`.

If you don't use a board, delete those three workflows and leave
`project_number` as the placeholder.

## Configure and enable

1. `install.sh` scaffolds `.devflow/config.json` from the template (only if
   absent). Fill in every `YOUR_*` placeholder and commit it — the workflows read
   it from the checked-out tree, so it must be committed (if your repo gitignores
   it, force-add: `git add -f .devflow/config.json`).
2. The `workflows` block in that file toggles each workflow on/off.
3. Make `Devflow Review` a required status check (Settings → Branches → branch
   protection) once you've confirmed it runs.

## Runtime provisioning (`setup`)

The `@claude` and `/devflow:implement` workflows prepare the runner **before**
Claude runs by reading a `setup` block from `.devflow/config.json`.
There is no hardcoded toolchain — DevFlow installs into repos of every shape
(Python package at root, npm frontend, Docker-only backend, polyglot), so you
declare what your project needs:

```json
"setup": {
  "python_version": "3.11",
  "node_version": "",
  "install": [
    "python -m pip install pyyaml",
    "pip install -e \".[dev]\"",
    "npm ci --prefix client"
  ]
}
```

- `python_version` / `node_version` gate the `actions/setup-python` /
  `actions/setup-node` steps — leave a value empty (`""`) to skip that language.
- `install` is an **array of shell lines**, joined with newlines and run
  verbatim after the language setups; leave it `[]` to install nothing.
- **Keep `python_version` set and `pip install pyyaml` present even for
  non-Python projects** — DevFlow's own helper scripts currently require
  Python ≥ 3.11 with PyYAML. List DevFlow's deps first, then your project's.

Example for a split repo (Docker backend in `server/`, npm frontend in
`client/`): keep `"python_version": "3.11"` + `pip install pyyaml`, set
`"node_version": "20"`, and add `npm ci --prefix client` to the `install` array.

## Extending the tool allowlist

`@claude` runs under a fixed `--allowed-tools` allowlist baked into the
workflows (git/gh, the DevFlow scripts, Python, and common read-only shell
tools). Provisioning a tool in `setup.install` does **not** let Claude *run* it
— the tool also has to be on the allowlist. To grant your repo's own commands,
add them on top of the built-in base list via config; you never edit the
workflow YAML:

```json
"claude": {
  "allowed_tools": ["Bash(make:*)", "Bash(docker compose:*)"]
},
"claude_implement": {
  "allowed_tools": ["Bash(make:*)", "Bash(terraform:*)"]
}
```

- Entries use [claude-code-action tool syntax](https://github.com/anthropics/claude-code-action)
  (e.g. `Bash(make:*)`), and are **appended** to DevFlow's base list — they add,
  never replace.
- The two keys are **independent**: `claude.allowed_tools` covers the light
  `@claude` path (`claude.yml`); `claude_implement.allowed_tools` covers the
  heavy `/devflow:implement` path (`claude-implement.yml`). The implement path
  does **not** inherit the light path's extras, so list every tool you want
  during implementation under `claude_implement.allowed_tools`.
- Leave a key out (or `[]`) to use the base list unchanged.
- These come from your committed config, so treat them with the same care as
  `setup.install`: only allowlist commands you trust to run unattended.

## Workflow inventory

| Workflow | Purpose | Needs |
|---|---|---|
| `ci.yml` | Runs DevFlow's own test suite | — (this repo's CI) |
| `claude.yml`, `claude-implement.yml`, `claude-runner.yml` | Run Claude Code skills in response to comments/events | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-review.yml` | Auto-runs `/devflow:review` as a gate on PRs | `CLAUDE_CODE_OAUTH_TOKEN` |
| `comment-on-draft-issues.yml` | Bot comments on new draft issues | GitHub App secrets |
| `move-to-in-progress.yml`, `sync-pr-status-to-issue.yml`, `close-released-items.yml` | Project-board status automation | `PROJECT_PAT` + board |

## A note on validation

After installing (or updating), run a low-stakes test before relying on the
automation: open a throwaway issue and `@claude` it, and confirm the run
provisions and responds. The CI permission model is settled — `install.sh`
vendors the plugin into the workspace, so its scripts resolve at the literal
`.claude/plugins/devflow/scripts/…` paths the workflows allowlist. (A
github-marketplace install is deliberately *not* used in CI: the Actions sandbox
can't reach `~/.claude`, and `CLAUDE_SKILL_DIR` is unset there.)
