---
name: init
description: Use when setting up DevFlow in a repo for the first time, or after a plugin update — scaffolds .devflow/config.json from the shipped template (only if absent) and refreshes config.schema.json. Invoke explicitly with /devflow:init.
disable-model-invocation: true
---

# DevFlow Init

Scaffold this repo's DevFlow config files. **One command does everything — do not hand-write `config.json` or guess field values.**

## Run

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/scaffold-config.sh"
```

This is the single shared scaffolder — the same script `install.sh` uses, so the two entry points can never drift. With no argument it targets the current repo root (git toplevel) and:

- creates `.devflow/config.json` from the shipped `config.example.json` **only if it does not already exist** — it never clobbers a config you've already filled in;
- always refreshes `.devflow/config.schema.json` so your editor validates against the current field set;
- **auto-detects the repo's language(s)** (Node, Go, Rust, Java, Ruby, PHP, .NET, Make, Docker) and **merges the matching build/test/lint tools** into `config.json` — into all three execution paths' allowlists (`claude.allowed_tools`, `claude_implement.allowed_tools`, `claude_runner.allowed_tools`) plus the `setup` block (`node_version` + a lockfile-appropriate install line, and a `composer install` line for PHP). This is what lets the automated reviewer actually build and test a PR. The merge is an **idempotent union**: it never removes your custom entries and never duplicates, so re-running after adding a language picks up only the new tools.

It resolves the templates from the installed plugin (`${CLAUDE_SKILL_DIR}/../../.devflow/`), so it works whether DevFlow was installed via the marketplace or vendored by `install.sh`.

## Then: enrich the `setup` block by exploring the repo

The scaffolder's language detection is a **deterministic floor** (marker file → known tool list + install line). It cannot infer a project's **service dependencies, runtime versions, or extensions** — those need judgement, which is your job. After it runs, **read the repo and fill in the `setup` fields a marker→list table can't**, editing `.devflow/config.json` directly (it's schema-validated; see `config.schema.json` for every field). Add **only what the project's tests actually need** — each addition runs in the cloud tier.

Inspect these sources and populate accordingly:

- **Service containers (`setup.services`)** — read `docker-compose.yml` / `compose.yaml`, `.env` / `.env.example`, framework DB config (e.g. `config/database.*`, `settings.py`, `application.yml`), `phpunit.xml`/test config, and any **pre-existing** `.github/workflows/*.yml` CI. If the test suite needs a database/cache/queue (MySQL, Postgres, Redis, RabbitMQ, …), add an entry per service with `name`, `image` (pin a version matching the project), `ports` (`"3306:3306"`), `env` (credentials/db name the tests expect), and an `options` health check so readiness is awaited — e.g. `"--health-cmd='mysqladmin ping -h 127.0.0.1' --health-interval=5s --health-timeout=5s --health-retries=20"`. Services are reachable on **`127.0.0.1:<host-port>`**, so make sure the project's *test* DB host is `127.0.0.1`/`localhost` (set it via `setup.install` or a test env file if needed).
- **PHP runtime (`setup.php_version`, `setup.php_extensions`)** — from `composer.json`'s `require.php` constraint set `php_version` (e.g. `"8.3"`); from `require`'s `ext-*` entries **and the services you added** set `php_extensions` (CSV) — e.g. a MySQL service implies `pdo_mysql`, a Redis service implies `redis`. Common: `"mbstring, intl, pdo_mysql, redis, bcmath"`.
- **Build/test commands (`setup.install`)** — the deterministic pass already adds `npm ci`/`composer install`. Add anything else the tests depend on running first, e.g. `npm run build` when tests need compiled assets, DB migrations (`php artisan migrate --env=testing`), or a test `.env` copy. Order matters — these run top-to-bottom after the language/PHP setup and service startup.
- **Tools the presets missed** — if the project drives tests through a tool not in `tool-presets.json` (a task runner, a custom binary), add `Bash(<tool>:*)` to the allowlists. Keep the same security caveat in mind (below).

This **complements** the preset floor; don't re-add what detection already wrote. Then tell the user to **review every addition before committing** and flag the security implication (next section).

## After running

Read the scaffolder's output line and respond accordingly:

- **`scaffolded …`** — a fresh `.devflow/config.json` was created. Every value has a working default, so it's usable as-is; tell the user they only need to edit it to customize (their editor validates against `config.schema.json`).
- **`keeping existing …`** — they already had a `config.json`; it was left untouched and only the schema was refreshed. Nothing more to do.

The scaffolder also prints `devflow-detect:` lines from the language auto-detection. Read them and respond:

- **`detected: <langs> — merged …`** — build/test tools for those languages were added to `config.json`. **Tell the user to review the additions before committing**, and flag the security implication plainly: these tools (e.g. `Bash(npm:*)`) run the PR author's code — including `npm`/`composer`/etc. install scripts — during the *automated reviewer* on `pull_request_target` with a write token. The reviewer reads them only from the base branch, so a PR can't grant itself tools, but the maintainer is opting into running untrusted build steps. If they don't want that, remove the entries from `claude_runner.allowed_tools` (and `setup`).
- **`detected: <langs> — config.json already covers them`** — idempotent re-run, nothing changed.
- **`no known language markers detected`** or **`jq not found …`** — no auto-population happened; the reviewer stays read-only. If they need build tools, point them at `claude_runner.allowed_tools` in `config.schema.json`.

There is **no trigger label** to create: in the cloud tier, `/devflow:implement` is started by commenting a bare `/devflow:implement <#>` on the issue (a native user event) — not by applying a label. The sender must be an allowed bot or an `allowed_users` collaborator with write access.

If the scaffolder exits non-zero (exit 2 = templates not found next to the script), the plugin install is incomplete. Tell the user to reinstall/update the DevFlow plugin (or run `install.sh` for the cloud tier). **Do not fall back to hand-writing the files** — that reintroduces exactly the drift this skill exists to prevent.
