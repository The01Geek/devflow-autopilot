# DevFlow Cloud Tier — GitHub Actions setup (optional)

The **local tier** (the skills you run inside Claude Code) needs none of this.
The **cloud tier** makes DevFlow run *autonomously* on your repository: Claude
responds to issue/PR events and `/devflow:review` runs as a required status
check. This guide sets that up.

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

Then review with `git diff` and commit. `.devflow/config.json` ships with a
working default for every value — edit it only to customize.

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

## Required secrets

Add these as repository (or environment) secrets under **Settings → Secrets and
variables → Actions**:

| Secret | Used for | Notes |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates the Claude Code action (`/devflow:implement`, `/devflow:review` runners) | From your Anthropic account. |
| `GITHUB_TOKEN` | (built in — no action needed) | Provided automatically to workflows. |

That's it — no GitHub App is required. (Earlier versions needed one purely so a
bot-authored "implement this" comment could re-trigger the workflow; a human
`/devflow:implement <#>` comment is itself a native user event, so that need is
gone.)

## Triggering `/devflow:implement`

`devflow-implement.yml` runs the full implementation lifecycle when a comment,
review, or new-issue body contains a bare `/devflow:implement <#>` (no `@claude`
required — and **no** `@claude`: a comment containing `@claude` is ceded to
Anthropic's Claude GitHub App, not DevFlow). There is no label trigger — a human
`/devflow:implement <#>` comment is the sole entry point and is itself a native
user event, so it needs no bot comment, PAT, or GitHub App.

> **Who can trigger it.** The `gate` job runs
> `scripts/resolve-implement-trigger.sh`, which authorizes the sender only if
> they are an allowed bot (`claude.allowed_bots`) **or** their login matches
> `claude.allowed_users` **and** they hold write / admin / maintain access — and
> fails closed otherwise. `claude.allowed_users` defaults to `"*"` (any
> collaborator) and can be narrowed to a comma-separated list of logins to
> restrict who may start a run; it only tightens the collaborator gate, never
> bypasses it. Bots are governed separately by `claude.allowed_bots` — this is
> the path for a custom GitHub App that posts the trigger comment on your behalf.
> The same gate guards the light `/devflow:*` command path in `devflow.yml`.
>
> **Early acknowledgement.** As soon as the gate authorizes a command, it adds a
> 🚀 reaction to the triggering comment (or, for a `/devflow:implement` issue
> body, the issue) via `scripts/react-to-trigger.sh` — so you can see the trigger
> was picked up well before the heavy job spins up. It's best-effort: a failed
> reaction never blocks the run, and a `/devflow:*` command submitted as a PR
> *review* gets no reaction (GitHub has no reactions API for reviews).

For the full idea → issue → PR walkthrough, see
[The workflow, end to end](../README.md#the-workflow-end-to-end) in the README.

## Configure and enable

1. `install.sh` scaffolds `.devflow/config.json` from the template (only if
   absent). Every value has a working default, so commit it as-is or edit to
   customize — the workflows read it from the checked-out tree, so it must be
   committed (if your repo gitignores it, force-add: `git add -f .devflow/config.json`).
2. The `workflows` block in that file toggles each workflow on/off.
3. Make `Devflow Review` a required status check (Settings → Branches → branch
   protection) once you've confirmed it runs.

## Runtime provisioning (`setup`)

The light command (`devflow.yml`) and `/devflow:implement` (`devflow-implement.yml`) workflows prepare the runner **before**
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

The light `/devflow:*` command path runs under a fixed `--allowed-tools` allowlist baked into the
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
  `/devflow:*` command path (`devflow.yml`); `claude_implement.allowed_tools` covers the
  heavy `/devflow:implement` path (`devflow-implement.yml`). The implement path
  does **not** inherit the light path's extras, so list every tool you want
  during implementation under `claude_implement.allowed_tools`.
- Leave a key out (or `[]`) to use the base list unchanged.
- These come from your committed config, so treat them with the same care as
  `setup.install`: only allowlist commands you trust to run unattended.

## Workflow inventory

| Workflow | Purpose | Needs |
|---|---|---|
| `ci.yml` | Runs DevFlow's own test suite | — (this repo's CI) |
| `devflow.yml` | Reusable runner (`workflow_call`) **and** the light `/devflow:*` command listener (review, review-and-fix, pr-description) | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-implement.yml` | Runs `/devflow:implement` on a bare command comment/issue | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-review.yml` | Auto-runs `/devflow:review` as a gate on PRs (calls `devflow.yml`'s runner) | `CLAUDE_CODE_OAUTH_TOKEN` |

DevFlow never creates or overwrites `claude.yml` — that file belongs to
Anthropic's Claude GitHub App, which owns plain `@claude` mentions, Q&A, and
`/security-review`. Every DevFlow trigger negates `@claude`, so the two never
double-fire; if a repo had an old DevFlow-authored `claude.yml`/`claude-runner.yml`/`claude-implement.yml`,
`install.sh` removes it on upgrade (a genuine Anthropic `claude.yml` is left untouched).

## A note on validation

After installing (or updating), run a low-stakes test before relying on the
automation: open a throwaway PR and comment a bare `/devflow:review` on it, and
confirm the run provisions and responds. The CI permission model is settled — `install.sh`
vendors the plugin into the workspace, so its scripts resolve at the literal
`.claude/plugins/devflow/scripts/…` paths the workflows allowlist. (A
github-marketplace install is deliberately *not* used in CI: the Actions sandbox
can't reach `~/.claude`, and `CLAUDE_SKILL_DIR` is unset there.)
