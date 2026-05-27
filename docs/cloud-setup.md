# DevFlow Cloud Tier — GitHub Actions setup (optional)

The **local tier** (the skills you run inside Claude Code) needs none of this.
The **cloud tier** makes DevFlow run *autonomously* on your repository: Claude
responds to issue/PR events and `/devflow:review` runs as a required status
check. This guide sets that up.

> Everything here is optional. Skip it entirely and DevFlow still works as an
> in-editor toolkit.

## Install (and update) the cloud tier

Run this from the root of your repository — it installs the workflows, composite
actions, a local `marketplace.json`, and a `.devflow/config.json` scaffold, and is
**idempotent, so the same command updates** to the latest later:

```bash
curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/main/install.sh | bash
# pin a version instead of tracking main:
#   curl -fsSL .../install.sh | DEVFLOW_REF=v1.2.0 bash
```

Then review with `git diff` and commit. `.devflow/config.json` ships with a
working default for every value — edit it only to customize.

This is a **thin install**: the bulky plugin tree is **not** committed to your
repo. The workflows fetch it at runtime (see below), pinned to the
`devflow_version` that `install.sh` writes into `.devflow/config.json` — the
commit it installed from. **To update**, bump `devflow_version` to a newer tag,
branch, or commit SHA (or just re-run the installer — now a small diff).
Re-running also **backfills any newly-added config keys** into your existing
`.devflow/config.json` (at any nesting depth) so you can discover and opt into
new features; values you've already set are preserved and your arrays (e.g.
`allowed_tools`) are left untouched. Because the pin is explicit, your CI never
silently tracks a moving `main`.

> **Prefer to commit the plugin instead?** Run `DEVFLOW_VENDOR=1 … | bash`. That
> vendors the full tree into `.devflow/vendor/devflow/` so nothing is fetched at
> runtime — self-hosting, fully auditable in your repo, at the cost of a large
> vendored diff on every update. `devflow_version` is then ignored.

### Why the plugin lives at a workspace path (not added as a github marketplace in CI)

The local skills locate their helpers via `${CLAUDE_SKILL_DIR}`, but in the
`claude-code-action` runner that variable is unset, the bash sandbox cannot read
`~/.claude` (where a marketplace plugin would install), and `$`-expansion in
commands is blocked. So the workflows reference helper scripts at the **literal
workspace path** `.devflow/vendor/devflow/scripts/…` — the plugin must physically
be at `.devflow/vendor/devflow/` when a job runs.

**Why `.devflow/vendor/` and not `.claude/`.** On every pull request,
`claude-code-action` runs a security step (`restoreConfigFromBase`) *before* it
installs plugins: for each of its `SENSITIVE_PATHS` — as of `claude-code-action`
v1, `.claude`, `.mcp.json`, `.claude.json`, `.gitmodules`, `.ripgreprc`,
`CLAUDE.md`, `CLAUDE.local.md`, `.husky` (see that action's
`src/github/operations/restore-config.ts` for the current set) — it deletes the
path (`rm -rf`) and then restores it from the **base branch**, so a PR can't
inject `.claude/` config into a trusted-token run. A
plugin vendored under `.claude/plugins/devflow/` is therefore wiped: the whole
`.claude/` directory is removed, and the base branch has no vendored tree to
restore, so the subsequent `plugin install` fails with `Source path does not
exist`. Vendoring to `.devflow/vendor/devflow/` — outside every `SENSITIVE_PATH`
— sidesteps the restore entirely; `claude-code-action` performs no other
working-tree-destructive step, so the runtime-vendored tree survives until
install. (A committed `DEVFLOW_VENDOR=1` tree at the old `.claude/` path used to
survive only because the restore re-checked-it-out from base — relocating makes
both install modes robust.)

A thin install satisfies that **at runtime** rather than by committing: every job
that needs the plugin runs the `vendor-plugin` composite action right after
checkout, which materializes the tree via a single deterministic algorithm —
**committed** (already in the checkout, e.g. a `DEVFLOW_VENDOR=1` install → used
as-is), **self** (the source repo, whose plugin lives at its own root → copied
in), or **fetch** (a thin consumer → clones `devflow_version` and copies it in —
shallow when it names a branch/tag, a full clone + checkout when it's the commit
SHA `install.sh` pins). The fetch branch refuses to run without a pinned
`devflow_version`, so a thin install never tracks mutable `main`.

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

`devflow-implement.yml` runs the full implementation lifecycle when a real
comment or review body contains a bare `/devflow:implement <#>` (no `@claude`
required — and **no** `@claude`: a comment containing `@claude` is ceded to
Anthropic's Claude GitHub App, not DevFlow). There is no label trigger — a human
`/devflow:implement <#>` comment is the sole entry point and is itself a native
user event, so it needs no bot comment, PAT, or GitHub App.

> **Who can trigger it.** The `gate` job runs
> `scripts/resolve-implement-trigger.sh`, which authorizes the sender only if
> they are an allowed bot (`devflow.allowed_bots`) **or** their login matches
> `devflow.allowed_users` **and** they hold write / admin / maintain access — and
> fails closed otherwise. `devflow.allowed_users` defaults to `"*"` (any
> collaborator) and can be narrowed to a comma-separated list of logins to
> restrict who may start a run; it only tightens the collaborator gate, never
> bypasses it. Bots are governed separately by `devflow.allowed_bots` — this is
> the path for a custom GitHub App that posts the trigger comment on your behalf.
> The same gate guards the light `/devflow:*` command path in `devflow.yml`.
>
> **Early acknowledgement.** As soon as the gate authorizes a command, it adds a
> 🚀 reaction to the triggering comment via `scripts/react-to-trigger.sh` — so you
> can see the trigger was picked up well before the heavy job spins up. It's
> best-effort: a failed reaction never blocks the run, and a `/devflow:*` command
> submitted as a PR *review* gets no reaction (GitHub has no reactions API for
> reviews).

For the full idea → issue → PR walkthrough, see
[The workflow, end to end](../README.md#the-workflow-end-to-end) in the README.

## Configure and enable

1. `install.sh` scaffolds `.devflow/config.json` from the template when absent;
   when it already exists it's kept and re-running only **backfills newly-added
   keys** from the template (existing values win, your arrays stay as-is). Every
   value has a working default, so commit it as-is or edit to customize — the
   workflows read it from the checked-out tree, so it must be committed (if your
   repo gitignores it, force-add: `git add -f .devflow/config.json`).
2. The `workflows` block in that file toggles each workflow on/off.
3. Make `Devflow Review` a required status check (Settings → Branches → branch
   protection) once you've confirmed it runs.

## Runtime provisioning (`setup`)

The light command (`devflow.yml`) and `/devflow:implement`
(`devflow-implement.yml`) always prepare the runner **before**
Claude runs by reading a `setup` block from `.devflow/config.json`; the
automated reviewer (`devflow-review.yml` → `devflow-runner.yml`) does so too,
but **only when you opt in** with `devflow_runner.provision_env: true` (see
"Letting the reviewer build/test a PR" below).
(`/devflow:init` auto-fills `node_version` + an install line from your repo's
language(s) and lockfile — see "Letting the reviewer build/test a PR" below.)
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
  verbatim **from the repo root** after the language setups; leave it `[]` to
  install nothing. A line that needs a subdirectory must `cd` into it itself
  (e.g. `(cd jsx && npm ci)` or `npm ci --prefix client`).
- **Keep `python_version` set and `pip install pyyaml` present even for
  non-Python projects** — DevFlow's own helper scripts currently require
  Python ≥ 3.11 with PyYAML. List DevFlow's deps first, then your project's.

Example for a split repo (Docker backend in `server/`, npm frontend in
`client/`): keep `"python_version": "3.11"` + `pip install pyyaml`, set
`"node_version": "20"`, and add `npm ci --prefix client` to the `install` array.

### PHP, service containers, and dependency caching

The `setup` block covers more than Python/Node, in this provisioning order
(**Python → Node → PHP → service containers → `install` lines**):

- **PHP** — set `setup.php_version` (e.g. `"8.3"`) to run
  [`shivammathur/setup-php`](https://github.com/shivammathur/setup-php) with
  Composer; `setup.php_extensions` is a CSV of extensions
  (`"mbstring, intl, pdo_mysql, redis"`), `setup.php_tools` an optional CSV of
  tools. `/devflow:init` fills these from `composer.json` and adds a
  `composer install` line.
- **Service containers** — `setup.services` starts databases/caches/queues your
  tests need, via `docker run` (DevFlow does **not** use GitHub Actions
  `services:` — those can't be defined in a composite action or driven by
  config). Each service is reachable on **`127.0.0.1:<host-port>`**, so point
  your *test* config at `127.0.0.1`. Give a `--health-cmd` in `options` so
  startup is awaited:

  ```json
  "setup": {
    "php_version": "8.3",
    "php_extensions": "mbstring, intl, pdo_mysql, redis",
    "services": [
      {
        "name": "mysql",
        "image": "mysql:8.0",
        "ports": ["3306:3306"],
        "env": { "MYSQL_ROOT_PASSWORD": "root", "MYSQL_DATABASE": "app_test" },
        "options": ["--health-cmd=mysqladmin ping -h 127.0.0.1 -uroot -proot", "--health-interval=5s", "--health-timeout=5s", "--health-retries=20"]
      },
      { "name": "redis", "image": "redis:7", "ports": ["6379:6379"] }
    ],
    "install": ["composer install --no-interaction", "php artisan migrate --env=testing --force"]
  }
  ```

  The runner has Docker preinstalled; the `docker` preset's `Bash(docker:*)`
  allowlist (auto-added when a `Dockerfile`/compose file is present) is what lets
  build steps talk to the containers.
- **Node dependency caching** — automatic: when `node_version` is set **and** a
  lockfile (`package-lock.json` / `yarn.lock` / `pnpm-lock.yaml` /
  `npm-shrinkwrap.json`) is present, `setup-node`'s download cache is enabled
  for the matching package manager. The lockfile is resolved under
  **`setup.node_working_directory`** — the repo root by default. No lockfile →
  caching is skipped (so it never errors).
- **Subdirectory / monorepo Node builds** — if your `package.json` + lockfile
  live in a subdirectory (a PHP/Rails app with a `/jsx` or `/resources/js`
  bundle, a monorepo `frontend/` package) rather than at the repo root, set
  `setup.node_working_directory` to that directory (e.g. `"jsx"`). Caching then
  keys off the lockfile there, and `/devflow:init` auto-detects it and scopes
  the generated Node install line into that directory (a subshell `cd`). Leave
  it empty/absent for a root-level build — provisioning is byte-for-byte the
  same as before. Remember `install` lines still run from the repo root, so any
  *additional* build line you add must scope itself into the subdirectory.

`/devflow:init` populates the deterministic parts (tool allowlists, `node_version`,
`npm ci`/`composer install`) from language markers, then **explores the repo**
(`docker-compose.yml`, `.env`, CI, `composer.json`) to enrich `php_version`,
`php_extensions`, and `services` — the judgement-heavy fields a marker→list table
can't infer. Review its additions before committing; service `env` and `install`
lines run in CI from your committed (base-branch) config.

## Extending the tool allowlist

The light `/devflow:*` command path runs under a fixed `--allowed-tools` allowlist baked into the
workflows (git/gh, the DevFlow scripts, Python, and common read-only shell
tools). Provisioning a tool in `setup.install` does **not** let Claude *run* it
— the tool also has to be on the allowlist. To grant your repo's own commands,
add them on top of the built-in base list via config; you never edit the
workflow YAML:

```json
"devflow": {
  "allowed_tools": ["Bash(make:*)", "Bash(docker compose:*)"]
},
"devflow_implement": {
  "allowed_tools": ["Bash(make:*)", "Bash(terraform:*)"]
}
```

- Entries use [claude-code-action tool syntax](https://github.com/anthropics/claude-code-action)
  (e.g. `Bash(make:*)`), and are **appended** to DevFlow's base list — they add,
  never replace.
- These keys are **independent**, one per execution path:
  `devflow.allowed_tools` → light `/devflow:*` command path (`devflow.yml`);
  `devflow_implement.allowed_tools` → `/devflow:implement` (`devflow-implement.yml`).
  None inherits another's extras, so list every tool you want for a given path
  under that path's key. The automated reviewer's build tools live in a third
  key, `devflow_runner.allowed_tools`, gated behind the `devflow_runner.provision_env`
  opt-in and bounded by a deny-list floor (see "Letting the reviewer build/test a
  PR" below).
- Leave a key out (or `[]`) to use the base list unchanged.
- These come from your committed config, so treat them with the same care as
  `setup.install`: only allowlist commands you trust to run unattended.

## Letting the reviewer build/test a PR

By default the automated reviewer is **read-only** — it inspects the diff but
cannot compile, lint, or test it, so a build-dependent claim (e.g. "does
`npx webpack` still compile after this change?") can only be flagged, not
verified. (Read-only still covers the live per-run `<!-- devflow:review-progress
run=<id>-<attempt> -->` progress comment: the `review` tool profile allow-lists `workpad.py`,
`config-get.sh`, and `efficiency-trace.sh` because those only edit the PR comment
via `gh` and read the run's state — they never mutate the tree. The
effectiveness-trace **record file** is the one piece gated to writable runs. See
[`workflow-triggers.md`](workflow-triggers.md) and
[`efficiency-trace.md`](efficiency-trace.md).) Read-only also covers
`resolve-review-overrides.py`, which the shared review engine runs to resolve the
per-subagent `devflow_review.agent_overrides` block — it only reads config via
`config-get.sh` and prints the resolved override map to stdout, never touching the
tree. For those overrides to take effect under the cloud `review` profile, that
script must be on the profile's tool allow-list (alongside the readers above); if
it is omitted, the engine's override resolution is denied and every override
silently falls back to `{}` (no override). See
[`review-agent-overrides.md`](review-agent-overrides.md). Flip one flag to opt in to
build/test:

```json
"devflow_runner": {
  "provision_env": true,
  "allowed_tools": ["Bash(npm:*)", "Bash(npx:*)", "Bash(node:*)"]
},
"setup": {
  "node_version": "20",
  "install": ["npm ci"]
}
```

When `devflow_runner.provision_env` is `true`, the runner (`devflow-runner.yml`)
does two extra things before launching Claude:

1. Runs the `setup-project-env` action — the same provisioning the
   `/devflow:*` command path and `/devflow:implement` already use (Python /
   Node / PHP → service containers → `setup.install`), so the reviewer has a
   real built environment. Service-container startup is best-effort: if a
   service fails to start or never becomes healthy, the runner prepends an
   infra-status note to the reviewer prompt naming the degraded service and
   instructing the reviewer to attribute any resulting build/test failures to
   infrastructure rather than the PR — so a transient outage surfaces as a clear
   caveat instead of silently degrading the review into a false "changes
   requested" verdict.
2. Extends the read-only `review` tool profile with the **freeform
   `devflow_runner.allowed_tools`** list from your base-branch config — read
   verbatim from the trusted base ref. This is **language-agnostic**: a Go shop
   lists `Bash(go:*)`, a Rust shop `Bash(cargo:*)`, and so on — no DevFlow
   release is needed per language. `/devflow:init` auto-populates it from your
   detected toolchain.

   Before appending, the runner enforces a deterministic **deny-list floor**: it
   strips file-mutation tools (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`) and
   any `Bash(…)` whose command-position binary is a raw shell / eval / privilege
   tool (`bash`, `sh`, `zsh`, `dash`, `ksh`, `fish`, `eval`, `exec`, `source`,
   `sudo`, `doas`, `su`) **or** an exec-wrapper that would run its argument as the
   real command (`env`, `xargs`, `nice`, `timeout`, `nohup`, `setsid`, `command`,
   `chroot`, `runuser`) — so `Bash(env bash:*)`, `Bash(/bin/bash:*)`,
   `Bash(FOO=1 bash:*)`, and `Bash(go;sudo:*)` are all stripped, while legitimate
   build entries whose *subcommand or argument* happens to be a deny word
   (`Bash(docker exec:*)`, `Bash(make CC=gcc:*)`) are kept. The runner emits a
   `::warning::` for each stripped entry and continues with the safe remainder, so
   this catastrophic tier can never reach the reviewer's write-token job no matter
   what `config.json` lists. (The floor blocks *direct* shell/privilege access; it
   does **not** try to block interpreters like `node -e` / `python -c`, which are
   legitimate build tools — enabling `provision_env` already means accepting that
   the reviewer runs the PR's build code.) If the
   list is empty (or empty after stripping) while `provision_env` is on, the
   runner warns that build-aware review is enabled with no build tools.

When the flag is **absent or `false` (the default)**, none of this happens: the
runner is byte-for-byte the read-only reviewer it was before — no provisioning
step, no build tools, no added latency, regardless of what
`devflow_runner.allowed_tools` contains.

The `setup` block is still populated for you: **`/devflow:init` auto-detects
your repo's language(s)** (Node, Go, Rust, Java, Ruby, PHP, .NET, Make, Docker)
from their marker files and fills in `setup` (picking `npm ci` /
`pnpm install` / `yarn install` from your lockfile). Re-run it after adding a
language — the merge is an idempotent union that never drops your custom
entries. Enabling the reviewer's build environment is then just setting
`provision_env: true`.

> **⚠️ Security — read before enabling.** Build tools run the **PR author's
> code** (e.g. an `npm` package's `postinstall` script) inside the reviewer,
> which fires on `pull_request_target` with a `pull-requests: write` token. To
> stop a PR from escalating itself, the runner reads **both** the
> `provision_env` flag **and** the `setup` block **only from your repo's base
> branch** — never from the PR's own checkout — so a malicious PR can neither
> turn provisioning on for its own review nor inject `setup.install` commands.
> But enabling `provision_env` is still you opting into running untrusted build
> steps against fork PRs. Mitigations: enable
> [*Require approval for all outside collaborators*](https://docs.github.com/en/actions/managing-workflow-runs/approving-workflow-runs-from-public-forks)
> for Actions, and keep `setup.install` to mainstream build/test/lint commands.
> Residual limitation: the reviewer still runs the in-repo composite actions
> (and the `setup.install` lines) from the PR checkout, so a PR that edits
> `.github/actions/**` is a separate, louder vector — protect those paths if
> this matters to you. Note too that the `setup` block comes from the base
> branch but runs against the PR-head tree, so a PR that restructures the
> project (renames the package dir, regenerates the lockfile) can make the
> base-pinned install line fail — surfacing as a provisioning error, not a code
> defect.

## Workflow inventory

| Workflow | Purpose | Needs |
|---|---|---|
| `ci.yml` | Runs DevFlow's own test suite | — (this repo's CI) |
| `devflow.yml` | Light `/devflow:*` command listener (review, review-and-fix, pr-description) — event-driven only, no `workflow_call` | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-runner.yml` | Reusable runner (`workflow_call`) — one read-only job called by `devflow-review.yml`; lives apart from `devflow.yml` so its permission ceiling stays a subset of the caller's grant | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-implement.yml` | Runs `/devflow:implement` on a bare command in a comment/review | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-review.yml` | Auto-runs `/devflow:review` as a gate on PRs (calls `devflow-runner.yml`) | `CLAUDE_CODE_OAUTH_TOKEN` |

DevFlow never creates or overwrites `claude.yml` — that file belongs to
Anthropic's Claude GitHub App, which owns plain `@claude` mentions, Q&A, and
`/security-review`. Every DevFlow trigger negates `@claude`, so the two never
double-fire; if a repo had an old DevFlow-authored `claude.yml`/`claude-runner.yml`/`claude-implement.yml`,
`install.sh` removes it on upgrade (a genuine Anthropic `claude.yml` is left untouched).

## A note on validation

After installing (or updating), run a low-stakes test before relying on the
automation: open a throwaway PR and comment a bare `/devflow:review` on it, and
confirm the run provisions and responds. The CI permission model is settled —
each plugin-using job runs the `vendor-plugin` action right after checkout, which
materializes the plugin at `.devflow/vendor/devflow/` (from the commit, the source
repo, or the pinned `devflow_version` fetch), so its scripts resolve at the literal
`.devflow/vendor/devflow/scripts/…` paths the workflows allowlist. (A
github-marketplace install is deliberately *not* used in CI: the Actions sandbox
can't reach `~/.claude`, and `CLAUDE_SKILL_DIR` is unset there.)
