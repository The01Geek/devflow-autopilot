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

`devflow_version` gets one narrow exception to "existing values are preserved":
the installer re-stamps it to the commit it just installed from **only when the
current value already looks like a commit SHA** (7-40 lowercase hex chars) or
is empty. This is a **shape heuristic, not true provenance detection** — the
installer cannot tell a SHA it auto-stamped on a previous run apart from a SHA
you hand-set yourself (e.g. to pin to one specific commit for reproducibility),
so a hand-pinned exact SHA is *not* guaranteed to survive a re-run. Only a
**non-SHA-shaped** hand pin — `"main"` to deliberately track the moving branch,
or a tag like `"v1.2.0"` — is guaranteed protected and left untouched on re-run.

> **Prefer to commit the plugin instead?** Run `DEVFLOW_VENDOR=1 … | bash`. That
> vendors the full tree into `.devflow/vendor/devflow/` so nothing is fetched at
> runtime — self-hosting, fully auditable in your repo, at the cost of a large
> vendored diff on every update. `devflow_version` is then ignored.

### Why the plugin lives at a workspace path (not added as a github marketplace in CI)

The local skills locate their helpers via the portable `${CLAUDE_SKILL_DIR:-…}` anchor (with a runner-reported base-directory fallback), but in the
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

> **Local editor use is different** — there you add this repo as a github
> marketplace with auto-update and never copy files. Running **`/devflow:init`
> provisions this for you** into the project `.claude/settings.json` (additively,
> never clobbering your values, idempotent on re-run), so you don't hand-edit it:
> ```jsonc
> // project .claude/settings.json — provisioned by /devflow:init
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
> On a **third-party model provider** (Bedrock / Vertex / Foundry) `/devflow:init`
> can additionally — **only with your explicit consent** — make
> `auto` permission mode **selectable** by writing `CLAUDE_CODE_ENABLE_AUTO_MODE="1"`
> into your **user-global** `~/.claude/settings.json` (it must be user scope —
> Claude Code filters this permission-gating env var out of project settings). It is
> *selectable, never on* (no `permissions.defaultMode` is written), preserves a
> deliberately-disabled `"0"`, and prints the one-line setting instead of writing if
> you decline. On the **Anthropic API the step is skipped** (auto mode is already
> available there by default). This is a **local-tier** convenience only — the cloud runner uses
> claude-code-action's own allowlist profile and consumes no `~/.claude/settings.json`.

## Required secrets

Add these as repository (or environment) secrets under **Settings → Secrets and
variables → Actions**:

| Secret | Used for | Notes |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates the Claude Code action (`/devflow:implement`, `/devflow:review` runners) | From your Anthropic account. |
| `GITHUB_TOKEN` | (built in — no action needed) | Provided automatically to workflows. |

That's the whole default — **no GitHub App is required**. (Earlier versions needed
one purely so a bot-authored "implement this" comment could re-trigger the
workflow; a human `/devflow:implement <#>` comment is itself a native user event,
so that need is gone.)

### Optional: a GitHub App for workflow-file pushes and a single DevFlow identity

DevFlow's cloud writers — `/devflow:implement` (`devflow-implement.yml`) and the
write-capable `/devflow:review-and-fix` path (`devflow.yml`'s `command` job) — push
to the feature branch using the built-in `GITHUB_TOKEN`. GitHub **hard-blocks**
`GITHUB_TOKEN` from creating or updating any file under `.github/workflows/`
(the push is refused: *"refusing to allow … to create or update workflow … without
`workflows` permission"*), and `actions: write` does not lift it. So a ticket whose
change legitimately edits a workflow file cannot be completed by the cloud tier on
the default credential. Separately, everything DevFlow posts on the default
credential — reviews, verdicts, reactions, notice comments — is attributed to
`github-actions[bot]`, and an approval from `github-actions[bot]` cannot satisfy a
"required approving reviews" branch-protection rule.

The optional App unlocks both: workflow-file pushes for the writers, and **one App
identity for DevFlow's non-review user-visible cloud posts** — the 👀/🚀 trigger
reactions and the notice comments (the named exceptions below stay on
`GITHUB_TOKEN`). The **review** agent's posts — its progress comment, verdicts,
approvals, and rejections — are deliberately **not** on this App: they run under the
separate `DevFlow-Reviewer` App (see below) so the review is never a self-review of a
PR this App authored. This is **opt-in**. When it is **not** configured, behavior is
byte-for-byte unchanged — no new secret or variable is required. To enable it,
create a GitHub App, install it on the repo, and configure:

| Kind | Name | Value |
|---|---|---|
| Repository **variable** | `DEVFLOW_APP_ID` | The App's client ID. |
| Repository **secret** | `DEVFLOW_APP_PRIVATE_KEY` | The App's PEM private key. |

The App must be **installed on the repo** with **`Contents: write`**,
**`Workflows: write`** (the writers' push path — `Workflows: write` alone cannot
commit, and `Contents: write` alone hits the original `workflows`-permission
refusal), plus **`Pull requests: write`**, **`Issues: write`**, and
**`Actions: read`** (the reaction/notice sites below, and the writers' CI reads).
The formal-review posts are **not** on this App — they run under the separate
DevFlow-Reviewer App (see below). Set the variable +
secret under **Settings → Secrets and variables → Actions** (the App ID is a
*variable*, the private key a *secret*).

With `DEVFLOW_APP_ID` set, each cloud site mints its own short-lived App
installation token (via `actions/create-github-app-token`) **downscoped to exactly
what that site does** — a job-scoped token cannot cross jobs, and the `permission-*`
mint inputs are the sole enforcement of least privilege (an App installation token
ignores the job's `permissions:` block):

| Site | Scope | Can |
|---|---|---|
| Writers' agent (`devflow-implement.yml` / `devflow.yml` `command` for `/devflow:pr-description` + `/devflow:review-and-fix`) | full installation scope | push, incl. `.github/workflows/` files |
| Trigger reactions + notices (`devflow.yml` / `devflow-implement.yml` `gate`, `devflow.yml` `review_dedupe`) | `issues: write` and/or `pull-requests: write` | add reactions, post notice comments — nothing more |

The **review agent** (`devflow-runner.yml`'s automated review, and `devflow.yml`'s manual `/devflow:review` command) is the one exception: it runs under a **separate** `DevFlow-Reviewer` App, not the primary one — see [The dedicated DevFlow-Reviewer app](#the-dedicated-devflow-reviewer-app-review-identity) below.

In the two **writer** jobs the App token is minted *before* `actions/checkout` and
passed to it as `token:`. This is load-bearing, not stylistic: the credential
`actions/checkout` persists — not the `github_token` handed to
`claude-code-action` — is what the agent's `git push` authenticates with.
`checkout@v6` writes its auth header to an external config file included via
`includeIf.gitdir:` rather than into `.git/config`, so `claude-code-action`'s
attempt to clear that header finds nothing, and the header it leaves behind
outranks the token that action embeds in `origin`'s URL. An unseeded checkout
therefore pushes as `github-actions[bot]`, which holds no `workflows`
permission — every ordinary push succeeds and only `.github/workflows/` pushes
fail, with `refusing to allow a GitHub App to create or update workflow …
without workflows permission`. Seeding the checkout puts the App token in that
header instead. When the App is unset the mint is skipped and the checkout
falls back to `GITHUB_TOKEN`, exactly as checkout would default on its own.

Every primary-App mint step is gated on `vars.DEVFLOW_APP_ID != ''`, so it is skipped
when the variable is unset and each consumer falls back to `GITHUB_TOKEN` (the two
review mints gate on the separate `vars.DEVFLOW_REVIEWER_APP_ID` — see the
DevFlow-Reviewer section below). A
configured-but-broken App (invalid or rotated key, or an installation missing one of
the permissions a site requests) **fails the job at the mint step** — there is no
silent fall-back to `GITHUB_TOKEN`. Named exceptions to the App identity: the
`Devflow Review` check-run (emitted by the Actions runner from the job `name:`,
not token-authored — it can never be App-authored), and the `/devflow:implement`
workpad comment, which is *created* on `GITHUB_TOKEN` by the gate job (detection
is marker-based — `<!-- devflow:workpad -->` — never author-based, so the
claude-job fallback creation running under the App token is harmless). The
stale-rejection housekeeping runs inside the review agent, so it uses whichever
token the runner holds (the downscoped DevFlow-Reviewer token when configured — its
dismissal needs only `pull-requests: write`, and dismissal works cross-identity).
This fail-loud contract covers every **primary-App** site — the writers' `gate`
jobs and the trigger-reaction/notice jobs: with a broken primary App configured,
even the trigger-reaction job fails rather than silently posting as
`github-actions[bot]` — fix the App's key/permissions, or unset `DEVFLOW_APP_ID` to
restore the default-token behavior. The read-only review run has the same fail-loud
contract, but under its own `DEVFLOW_REVIEWER_APP_ID` (unset *that* to restore the
review run's default token) — see the DevFlow-Reviewer section below.

### The dedicated DevFlow-Reviewer app (review identity)

GitHub forbids **requesting changes on — or approving — your own pull request**.
Without a dedicated reviewer identity, DevFlow's review agent would run under the
same identity that DevFlow uses to *author* PRs (the primary App above, or
`github-actions[bot]`), so Phase 4.4's
`gh pr review --request-changes` / `--approve` would be a forbidden self-review:
the merge stays blocked by the required `Devflow Review` status check, but no
**visible** formal review (`reviewDecision`) is recorded. To restore the visible
formal review, run the review agent under a **dedicated second GitHub App**,
**`DevFlow-Reviewer`**, whose identity is distinct from the PR author.

| Kind | Name | Value |
|---|---|---|
| Repository **variable** | `DEVFLOW_REVIEWER_APP_ID` | The DevFlow-Reviewer App's ID (or client ID). |
| Repository **secret** | `DEVFLOW_REVIEWER_PRIVATE_KEY` | The DevFlow-Reviewer App's PEM private key. |

Create and install a second GitHub App on the repo with
**`Contents: read`**, **`Issues: read`**, **`Pull requests: write`**, and **`Actions: read`** —
the downscoped review permission set (it reads the repo/issue/CI and posts comments,
reviews, approvals, and rejections; it **cannot push**). Set the variable + secret
under **Settings → Secrets and variables → Actions**, mirroring the primary-App
convention.

**Review-identity invariant.** Every review path — the automated runner
(`devflow-runner.yml`) and the manual `/devflow:review` command (`devflow.yml`) —
uses the `DevFlow-Reviewer` installation token when `vars.DEVFLOW_REVIEWER_APP_ID`
is set, otherwise `github-actions[bot]` (`GITHUB_TOKEN`). The review path **never**
uses the primary `devflow-autopilot` App token. Since implement authors PRs as the
primary App (or `github-actions[bot]` when no App is configured), the review
identity is structurally distinct from the author on every configured setup, so
Phase 4.4's formal review posts instead of failing self-review. `/devflow:pr-description`
and `/devflow:review-and-fix` are unchanged — they still use the primary App token
(they push/author, and `review-and-fix` posts no formal review). The mint is gated
and fail-loud exactly like the primary App: unset reviewer variable → `GITHUB_TOKEN`
fallback; a configured-but-broken reviewer App fails the job at the mint step.

> **Upgrade note (deliberate behavior change).** If you already run DevFlow with a
> single App (`DEVFLOW_APP_ID` set) and do **not** configure `DevFlow-Reviewer`,
> your review attribution moves from your DevFlow App to `github-actions[bot]`
> until you set `DEVFLOW_REVIEWER_APP_ID` + `DEVFLOW_REVIEWER_PRIVATE_KEY`. This is
> intentional: the review path no longer borrows the PR-authoring App identity, so
> the same-identity self-review collision cannot occur. A `github-actions[bot]`
> approval does not satisfy a "required approving reviews" branch-protection rule,
> so configure `DevFlow-Reviewer` if you rely on that.
>
> **Degenerate zero-app config.** With neither `DEVFLOW_APP_ID` nor
> `DEVFLOW_REVIEWER_APP_ID` set, implement and review are both
> `github-actions[bot]`, so the self-approval collision persists on that config —
> the `gh pr comment` fallback and the required `Devflow Review` check still apply.

The same App token also powers the implement workflow's **stall-backstop
auto-resume** (see `docs/implement-skill.md`): a `/devflow:implement <#>` resume
comment authored by the built-in `GITHUB_TOKEN` never re-triggers the workflow
(GitHub suppresses recursive `GITHUB_TOKEN` events), so without the App the
backstop posts its resume comment and then fails the job loud instead of
pretending the resume happened — a human re-posts the trigger comment manually.
With the App configured, also add the App's bot login (e.g. `your-app[bot]`) to
`devflow.allowed_bots` in `.devflow/config.json`, or the gate's actor
authorization declines the App-authored resume comment. Because a `claude` job
can run longer than an App installation token's ~60-minute lifetime, the backstop
mints its **own fresh** App token just-in-time immediately before it runs rather
than reusing the token minted at the job's start; a `gh`-api/transport/auth
failure reading the workpad (e.g. an expired token) is a distinct `auth-failure`
class that fails the job loud **without** consuming a resume attempt, so a healthy
workpad behind a bad token is never misclassified as corrupt (see
`docs/implement-skill.md`). The resume comment carries an inline `Resume note:`
that instructs the resumed run to invoke bundled helpers with the repo-relative
vendored literal (`.devflow/vendor/devflow/scripts/…`, `.devflow/vendor/devflow/lib/…`)
as the command's leading token — never an absolute path, never repo-root
`scripts/…`, never behind a `VAR=` prefix or `bash <path>` wrapper — since the
cloud allowlist silently denies any other form, which is exactly what killed
prior auto-resume runs on their first helper call (issue #405).

The same App token **also** powers the review workflow's **no-verdict
auto-resume backstop** (`devflow_review.stall_backstop`, issue #408 — the
review-side sibling of the implement backstop above; see
`docs/DEVFLOW_SYSTEM_OVERVIEW.md`). A headless cloud review can end `success`
with no verdict (the early-quit timing race); when that happens the auto-review
path (`devflow-review.yml`'s `finalize_check`) mints its **own fresh** App token
just-in-time and authors a `/devflow:review` re-trigger comment so the review
re-runs without a human. As with the implement resume, a `GITHUB_TOKEN`-authored
comment never re-triggers the workflow, so this needs the App: with `DEVFLOW_APP_ID`
unset the backstop degrades to the dead-end flip (a visible `❌ Review failed`
that a human must re-trigger). And exactly like the implement resume, add the
minting App's bot login (e.g. `your-app[bot]`) to `devflow.allowed_bots` in
`.devflow/config.json`, or the manual-`/devflow:review` gate the re-trigger
re-enters declines the App-authored comment. The backstop is capped at
`devflow_review.stall_backstop.max_resume_attempts` (default `2`) per head and
gated by `devflow_review.stall_backstop.enabled` (default `true`, disabled only
on a real JSON `false`); when the cap is exhausted, disabled, or no App token is
configured it reports no-fire and degrades to the dead-end flip.

> **Loop-safety note.** Unlike `GITHUB_TOKEN` pushes (which GitHub suppresses from
> re-triggering workflows), an **App-token push re-triggers workflows**. For DevFlow
> this is mostly desirable (a push to a non-draft PR re-runs `Devflow Review` on its
> own). Loop-safety does **not** rest on the push-suppression: it rests on the
> `@claude`-negation **partition invariant** (every DevFlow trigger negates `@claude`,
> so DevFlow and Anthropic's stock `claude.yml` never double-fire) and on
> `/devflow:implement` triggering from an `issue_comment` (a human action) rather than
> from `push`. Do not weaken those `if:` clauses.

## Triggering `/devflow:implement`

`devflow-implement.yml` runs the full implementation lifecycle when a real
comment **on an issue** contains a bare `/devflow:implement <#>` (no `@claude`
required — and **no** `@claude`: a comment containing `@claude` is ceded to
Anthropic's Claude GitHub App, not DevFlow). There is no label trigger — a human
`/devflow:implement <#>` comment is the sole entry point and is itself a native
user event, so it needs no bot comment, PAT, or GitHub App.

It is **issues-only**: the workflow subscribes to `issue_comment[created]` alone,
and because a PR comment is also an `issue_comment` in GitHub's API, the `gate`
job's `if:` requires `github.event.issue.pull_request == null` (with the resolver
re-checking via an `IS_PULL_REQUEST` backstop), so a comment on a pull request
never starts a run. This is what stops the weekly retrospective's audit-report
comment — which quotes the literal `/devflow:implement` phrase in prose on the
state PR — from self-triggering an implement run. The light `/devflow:review` and
`/devflow:pr-description` commands in `devflow.yml` remain PR-aware and are
unaffected.

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

### Grant your test/lint commands so the run verifies in-env (issue #405)

`/devflow:implement` verifies **in its own environment, never via CI**. A
verification-command acceptance criterion — one whose verification is *running a
test/lint/build command* (your test suite, a linter, a `pytest`/build
invocation) — is ticked only on a pass the run **observes in-env**. The run
never waits on, polls, re-checks, or cites CI for its own progress; CI remains
the **required post-PR check that gates the human merge**, not an in-run
verification channel.

For the run to actually run those commands, they must be on the allowlist for
the execution path — invoked by their **direct leading-token** form (the
`bash <path>` wrapper is deny-floored and can never be granted). So:

- List your project's test/lint commands under **`devflow_implement.allowed_tools`**
  (the `/devflow:implement` path) **and** under **`devflow.allowed_tools`** (the
  `/devflow:*` command path, including `/devflow:review-and-fix`):

  ```json
  "devflow": {
    "allowed_tools": ["Bash(npm test:*)", "Bash(npm run lint:*)"]
  },
  "devflow_implement": {
    "allowed_tools": ["Bash(npm test:*)", "Bash(npm run lint:*)"]
  }
  ```

- **Leave them ungranted and the run does not silently defer to CI** — a
  verification-command AC goes **`Blocked`**, and the Blocked message names
  `devflow_implement.allowed_tools` as the exact remedy: grant the command so
  the run can verify in-env, then re-run. There is never a silent stall, and
  never a verdict resting on a CI result the run never saw.

(This repo's own `.devflow/config.json` grants `Bash(lib/test/run.sh:*)`,
`Bash(lib/preflight.sh:*)`, and `Bash(shellcheck:*)` under both keys for exactly
this reason.) See [`implement-skill.md`](implement-skill.md) for the Phase 3.4
gate behavior.

## Letting the reviewer build/test a PR

By default the automated reviewer is **read-only** — it inspects the diff but
cannot compile, lint, or test it, so a build-dependent claim (e.g. "does
`npx webpack` still compile after this change?") can only be flagged, not
verified. (Read-only still covers the live per-run `<!-- devflow:review-progress
run=<id>-<attempt> -->` progress comment: the `review` tool profile allow-lists `workpad.py`,
`config-get.sh`, `load-prompt-extension.sh`, and `efficiency-trace.sh` because those only
edit the PR comment via `gh`, read config, read the run's state, or `cat` a consumer-owned
prompt-extension file — they never mutate the tree. (`load-prompt-extension.sh` is the
standardized preflight every skill now runs — including `review` and `review-and-fix` — so
it must be on the read-only profile too, or the convention would silently no-op in the cloud
review tier.) The
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
   strips file-mutation tools (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`) —
   matched by tool **name** (the token before the first `(`, compared
   case-insensitively), so a **parameterized** entry like `Write(**)`,
   `Edit(src/**)`, or `notebookedit(x)` is stripped exactly like the bare name —
   and any `Bash(…)` whose command-position binary is a raw shell / eval /
   privilege tool (`bash`, `sh`, `zsh`, `dash`, `ksh`, `fish`, `eval`, `exec`,
   `source`,
   `sudo`, `doas`, `su`) **or** an exec-wrapper that would run its argument as the
   real command (`env`, `xargs`, `nice`, `timeout`, `nohup`, `setsid`, `command`,
   `chroot`, `runuser`) — so `Bash(env bash:*)`, `Bash(/bin/bash:*)`,
   `Bash(FOO=1 bash:*)`, and `Bash(go;sudo:*)` are all stripped, while legitimate
   build entries whose *subcommand or argument* happens to be a deny word
   (`Bash(docker exec:*)`, `Bash(make CC=gcc:*)`) are kept. The runner emits a
   `::warning::` for each stripped entry and continues with the safe remainder, so
   this catastrophic tier can never reach the reviewer's write-token job no matter
   what `config.json` lists. The floor's filter code itself is executed only from
   a **trusted source** — a copy materialized from your base branch, or the
   vendored copy when it was freshly fetched this run at the pinned
   `devflow_version` — never from the PR-head checkout, so a pull request cannot
   edit the filter that governs its own review; when no trusted copy is
   available the runner fails closed (no build tools appended). (The floor blocks *direct* shell/privilege access; it
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

### What the reviewer is told before it starts — the engine ground-truth block

Every cloud run of `/devflow:review` — the automated `devflow-review.yml` path and the
manual `/devflow:review` comment path alike — has a `> [!IMPORTANT]` **engine
ground-truth** block prepended to its prompt by `scripts/render-grounding-block.sh`. The
block states two facts the engine would otherwise spend turns rediscovering by attempting
commands and collecting denials:

1. **The CI results observed for the reviewed commit**, rendered by
   `scripts/summarize-ci-checks.sh` from the GitHub API. These are the **observed**
   conclusions — including a `failure` conclusion and an `in_progress` status — never a
   green assumption. When the CI state cannot be determined the block says
   `CI status unavailable`; an unknown state is never rendered as a passing one.
2. **The exact `--allowed-tools` string this run resolved**, quoted verbatim from the
   same value the runner passes to the engine, so the two cannot drift.

Check-run and job names inside the block are attacker-controlled text (any pull request
can add a workflow whose job `name:` is arbitrary), so they are sanitized, truncated, and
rendered inside a plain ` ```text ` fence, beneath prose that declares the names untrusted
data. The block tells the engine to quote a name, never to obey one — while treating the
conclusions beside them as the API facts they are.

**How this interacts with `require_ci_green`.** On the **auto** path the review is
triggered by `devflow-review.yml`'s `workflow_run` `[completed]` trigger and gated by
`scripts/derive-review-preconditions.sh`, whose `require_ci_green` precondition (default
`true`) defers the review until every other CI signal on the head has completed without
failing. CI completion is therefore a *precondition of the reviewer's invocation* on that
path, and the block's CI section normally reports completed, non-failing checks.

**The one path that bypasses it:** a `check_run[rerequested]` event — clicking **Re-run**
on the `Devflow Review` check — is deliberately left ungated by the preconditions (that is
what makes "Click Re-run … to force a review" true). A forced Re-run can therefore reach
the engine while CI is still running or after it failed. This is exactly why the block
reports *observed* conclusions rather than asserting green: on such a run the engine sees
`in_progress` or `failure` and reports it, instead of being told CI passed.

### Where the `review` profile grants its helpers — the path prefix matters

The read-only `review` profile grants its bundled helpers under the **vendored path prefix
`.devflow/vendor/devflow/`** — e.g. `Bash(.devflow/vendor/devflow/scripts/workpad.py:*)`,
`Bash(.devflow/vendor/devflow/scripts/config-get.sh:*)`,
`Bash(.devflow/vendor/devflow/lib/efficiency-trace.sh:*)`. That prefix is not decoration:
Claude Code matches a `Bash(...)` rule against the command's **leading token after
expansion**, so a helper invoked by any other path — or through a `bash <path>` wrapper —
matches nothing and is silently denied.

The one exception is `load-prompt-extension.sh`, granted **directory-agnostically** as
`Bash(*/load-prompt-extension.sh:*)`. The final-pass reviewer (`requesting-code-review`) is
dispatched as an *installed skill*, so its `${CLAUDE_SKILL_DIR}` anchor resolves to the
plugin checkout rather than the vendored tree; without the wildcard rule its prompt-extension
load is denied and the consumer's extension silently never loads for that reviewer.

## Effectiveness telemetry on the cloud `/devflow:implement` job

`/devflow:implement`'s Phase 3.3 drives `review-and-fix` **inline in the orchestrator's
context**, and that loop persists a per-run effectiveness record under
`.devflow/logs/efficiency/` (see [`efficiency-trace.md`](efficiency-trace.md)). Two properties
matter for the cloud tier:

- **The per-iteration `iter-<N>.json` emit is a non-optional obligation on every iteration,
  however the loop was executed** — whether `review-and-fix` ran as a `Skill` invocation or was
  **hand-run via direct `Agent` dispatch** under sandbox friction — and it is written **with the
  Write tool, never a shell `>`/heredoc redirect** the cloud sandbox denies into `.devflow/tmp`.
  A `claude-code-action` permission/sandbox denial is not the local-tier permission classifier and
  is **not** license to leave the instrumented loop: on the implement job `Skill`, `Agent`, `Write`,
  `efficiency-trace.sh`, `workpad.py`, and `config-get.sh` are all allow-listed, so the loop is
  navigable, not blocked. This guarantees the **effectiveness** half of the telemetry
  (dispatch counts, findings, verdicts, fix decisions) is captured even on a degraded run. The
  **token/wall-clock cost** half is *live-only* — it cannot be reconstructed once the loop is
  abandoned, so it has **no deterministic guarantee**; keeping the loop live is its only (probabilistic)
  protection.
- **Implement-vs-runner `--permission-mode` asymmetry.** The read-only `review` runner
  (`devflow-runner.yml`) launches Claude with `--permission-mode acceptEdits`; the
  `/devflow:implement` job (`devflow-implement.yml`) deliberately does **not**. So the implement seam
  reduces friction through the `#275`/`#284` portability discipline — single-statement, leading-token
  helper invocations and the Write tool for scratch files — rather than by widening the permission
  grant. `acceptEdits` would not help here anyway: it auto-approves `Edit`/`Write` plus some
  filesystem `Bash`, not the piped/compound `.sh` forms that were the primary denial.

## Workflow inventory

| Workflow | Purpose | Needs |
|---|---|---|
| `ci.yml` | Runs DevFlow's own test suite | — (this repo's CI) |
| `devflow.yml` | Light `/devflow:*` command listener (review, review-and-fix, pr-description) — event-driven only, no `workflow_call` | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-runner.yml` | Reusable runner (`workflow_call`) — one read-only job called by `devflow-review.yml`; lives apart from `devflow.yml` so its permission ceiling stays a subset of the caller's grant | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-implement.yml` | Runs `/devflow:implement` on a bare command in an issue comment (issues-only; PR comments never fire it) | `CLAUDE_CODE_OAUTH_TOKEN` |
| `devflow-review.yml` | Auto-runs `/devflow:review` as a gate on PRs (calls `devflow-runner.yml`). Its `workflow_run` re-trigger — which re-fires a review deferred behind the `devflow_review.require_up_to_date` / `require_ci_green` preconditions (issue #304) — **must name your repo's CI workflows** in its `workflows:` list (ships as `[CI]`; a GitHub platform requirement, no wildcards) — edit that list when installing. External non-Actions CI is covered by `check_suite`, and legacy commit-status-only CI (classic Jenkins, legacy CircleCI) by the `status` trigger — both need no naming | `CLAUDE_CODE_OAUTH_TOKEN` |

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
