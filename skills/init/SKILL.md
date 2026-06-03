---
name: init
description: Use when setting up DevFlow in a repo for the first time, or after a plugin update — scaffolds .devflow/config.json from the shipped template (when absent) or backfills newly-added keys into an existing one (preserving your values), and refreshes config.schema.json. Invoke explicitly with /devflow:init.
disable-model-invocation: true
---

# DevFlow Init

Scaffold this repo's DevFlow config files. **One command does everything — do not hand-write `config.json` or guess field values.**

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh init
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

## Run

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/scaffold-config.sh"
```

This is the single shared scaffolder — the same script `install.sh` uses, so the two entry points can never drift. With no argument it targets the current repo root (git toplevel) and:

- creates `.devflow/config.json` from the shipped `config.example.json` **only if it does not already exist** — it never clobbers a config you've already filled in. When the config already exists it's kept and re-running **backfills any newly-added keys** from the example (at any nesting depth) so you can opt into new features; values you've already set always win and arrays you've tuned (e.g. `allowed_tools`) are left as-is;
- always refreshes `.devflow/config.schema.json` so your editor validates against the current field set;
- **auto-detects the repo's language(s)** (Node, Go, Rust, Java, Ruby, PHP, .NET, Make, Docker) and **merges the matching build/test/lint tools** into `config.json` — into all three allowlists (`devflow.allowed_tools`, `devflow_implement.allowed_tools`, and `devflow_runner.allowed_tools`, which the automated reviewer consumes when `devflow_runner.provision_env: true` — see below) plus the `setup` block (`node_version` + a lockfile-appropriate install line, and a `composer install` line for PHP). When the Node `package.json`/lockfile lives in a **subdirectory** (a monorepo `frontend/` package, or a PHP/Rails app with a co-located `/jsx` or `/resources/js` bundle), it is auto-detected into `setup.node_working_directory` and the generated Node install line is scoped into that directory (a subshell `cd`) so caching and the build target the right place; a root-level build leaves `node_working_directory` empty. The `setup` block is what lets the automated reviewer build/test a PR — but only once the maintainer opts in with `devflow_runner.provision_env: true` (see "Letting the reviewer build/test a PR" in docs/cloud-setup.md). The merge is an **idempotent union**: it never removes your custom entries and never duplicates, so re-running after adding a language picks up only the new tools.

It resolves the templates from the installed plugin (`${CLAUDE_SKILL_DIR}/../../.devflow/`), so it works whether DevFlow was installed via the marketplace or vendored by `install.sh`.

## Then: verify the runtime dependencies are present

The scaffolder needs only `jq`, but **running** DevFlow's skills needs more — and **PyYAML is the one dependency people miss**, because `/plugin install` resolves companion *plugins* and never runs `pip`. Config itself is JSON (read by a Node resolver, no PyYAML), so a missing PyYAML doesn't break scaffolding — but it silently degrades the runtime Python helpers that parse YAML blocks in PR/issue bodies (`match-deferrals.py`, `workpad.py`). So after scaffolding, run the preflight check and surface any gap:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/preflight.sh"
```

This verifies `git`, `gh`, `jq`, `python3` (>=3.11), and **PyYAML**, printing an actionable line per missing item and exiting non-zero if any is absent. It's **advisory** — scaffolding already succeeded, so a non-zero exit here is a dependency gap to *report*, not an init failure. **Never run `pip` yourself**: DevFlow deliberately keeps `pip` out of the plugin/init path, so relay the install command and let the user run it (see "After running"). Read the result and respond per the matching branch below.

## Then: enrich the `setup` block by exploring the repo

The scaffolder's language detection is a **deterministic floor** (marker file → known tool list + install line). It cannot infer a project's **service dependencies, runtime versions, or extensions** — those need judgement, which is your job. After it runs, **read the repo and fill in the `setup` fields a marker→list table can't**, editing `.devflow/config.json` directly (it's schema-validated; see `config.schema.json` for every field). Add **only what the project's tests actually need** — each addition runs in the cloud tier.

Inspect these sources and populate accordingly:

- **Service containers (`setup.services`)** — read `docker-compose.yml` / `compose.yaml`, `.env` / `.env.example`, framework DB config (e.g. `config/database.*`, `settings.py`, `application.yml`), `phpunit.xml`/test config, and any **pre-existing** `.github/workflows/*.yml` CI. If the test suite needs a database/cache/queue (MySQL, Postgres, Redis, RabbitMQ, …), add an entry per service with `name`, `image` (pin a version matching the project), `ports` (`["3306:3306"]`), `env` (credentials/db name the tests expect), and an `options` **array** with a health check so readiness is awaited — e.g. `["--health-cmd=mysqladmin ping -h 127.0.0.1", "--health-interval=5s", "--health-timeout=5s", "--health-retries=20"]` (one complete docker arg per element). Services are reachable on **`127.0.0.1:<host-port>`**, so make sure the project's *test* DB host is `127.0.0.1`/`localhost` (set it via `setup.install` or a test env file if needed).
- **PHP runtime (`setup.php_version`, `setup.php_extensions`)** — from `composer.json`'s `require.php` constraint set `php_version` (e.g. `"8.3"`); from `require`'s `ext-*` entries **and the services you added** set `php_extensions` (CSV) — e.g. a MySQL service implies `pdo_mysql`, a Redis service implies `redis`. Common: `"mbstring, intl, pdo_mysql, redis, bcmath"`.
- **Build/test commands (`setup.install`)** — the deterministic pass already adds `npm ci`/`composer install`. Add anything else the tests depend on running first, e.g. `npm run build` when tests need compiled assets, DB migrations (`php artisan migrate --env=testing`), or a test `.env` copy. Order matters — these run top-to-bottom after the language/PHP setup and service startup.
- **Tools the presets missed** — if the project drives tests through a tool not in `tool-presets.json` (a task runner, a custom binary), enrich the allowlists per the next section.

This **complements** the preset floor; don't re-add what detection already wrote. Then tell the user to **review every addition before committing** and flag the security implication (next section).

## Then: enrich the three allowlists by exploring the repo's real build/test/lint setup

The preset floor (`detect-project-tools.sh` + `tool-presets.json`) is a deterministic marker→tool-list lookup. It is intentionally conservative and will miss project-specific tooling. **Explore the repo's actual build/test/lint setup** — `Makefile`, `package.json` scripts, `composer.json` scripts, `pyproject.toml`/`tox.ini`, `justfile`/`Taskfile.yml`, CI workflows, test-runner configs — and add anything the presets missed to all three allowlists, editing `.devflow/config.json` directly:

- `devflow.allowed_tools` — the light `/devflow:*` command path.
- `devflow_implement.allowed_tools` — `/devflow:implement` (this path legitimately needs `Edit`/`Write`; it writes code).
- `devflow_runner.allowed_tools` — the automated reviewer's build/verify tools, appended to its read-only profile **only when `devflow_runner.provision_env: true`**, read from the trusted base ref.

**Attach a one-line justification to every entry you add** (in your message to the user, e.g. "`Bash(go:*)` — repo is Go; `go build`/`go test` drive verification"). **Grant *enough* access for the automations to be effective** — a reviewer that can't run the project's real `make test` / `cargo test` / `go build` is crippled and will punt build-dependent claims. Worked examples:

- Go repo → `devflow_runner.allowed_tools`: `Bash(go:*)` (build/test/vet), `Bash(golangci-lint:*)` (lint). Justify: "reviewer compiles + lints the PR."
- Rust repo → `Bash(cargo:*)`, `Bash(rustc:*)`. Justify: "`cargo test`/`cargo clippy` are the verification path."
- Make-driven repo → `Bash(make:*)`. Justify: "tests run via `make test`."

### Security — the `pull_request_target` + write-token threat model

The automated reviewer fires on `pull_request_target` with a `pull-requests: write` token, and when `provision_env` is on it runs the **PR author's** build code. So when enriching `devflow_runner.allowed_tools`:

- **Prefer narrow scoped patterns.** `Bash(go test:*)` is safer than `Bash(go:*)` when only test is needed; scope to the subcommand the reviewer actually uses.
- **Never add a deny-listed tool to *any* allowlist.** The runner deterministically strips file-mutation tools (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`) and raw-shell/eval/privilege Bash (`Bash(bash:*)`, `Bash(sh:*)`, `Bash(zsh:*)`, `Bash(eval:*)`, `Bash(exec:*)`, `Bash(source:*)`, `Bash(sudo:*)`) from the reviewer's profile and warns — so proposing one is pointless for the reviewer and dangerous everywhere else. Do not propose any of them.
- **Tell the maintainer to review `config.json` before committing**, and to keep `provision_env` off (the default) unless they accept running untrusted PR build steps.

## After running

Read the scaffolder's output line and respond accordingly:

- **`scaffolded …`** — a fresh `.devflow/config.json` was created. Every value has a working default, so it's usable as-is; tell the user they only need to edit it to customize (their editor validates against `config.schema.json`).
- **`keeping existing …`** — they already had a `config.json`; their values were preserved. It may be followed by **`backfilled newly-added keys …`** when the upgrade added keys the example gained since their config was written (existing values and arrays untouched) — tell the user to review the small diff before committing. If only `keeping existing …` prints, the config already had every key and nothing changed.

The scaffolder also prints `devflow-detect:` lines from the language auto-detection. Read them and respond:

- **`detected: <langs> — merged …`** — build/test tools for those languages were added to `config.json`. **Tell the user to review the additions before committing.** The `devflow_runner.allowed_tools` entries reach the automated reviewer only when `devflow_runner.provision_env: true` is set in the base-branch config, which runs the PR author's `setup.install` + build steps on `pull_request_target` with a write token. The flag and the freeform allowlist are read only from the base branch, so a PR can't enable it or grant itself tools, and the runner strips the deny-listed tier regardless; but enabling `provision_env` is opting into running untrusted build steps. If they want the reviewer read-only (the default), leave `provision_env` unset/false. The `devflow.allowed_tools` / `devflow_implement.allowed_tools` entries take effect in their own workflows.
- **`detected: <langs> — config.json already covers them`** — idempotent re-run, nothing changed.
- **`no known language markers detected`** or **`jq not found …`** — no auto-population happened; the reviewer stays read-only. To make the reviewer build/test PRs they must set `devflow_runner.provision_env: true` and populate the `setup` block (see `config.schema.json` / docs/cloud-setup.md).

Then branch on the preflight **exit code** (the durable signal — every line it prints carries the stable `devflow preflight:` prefix, but the wording can change; the exit code won't):

- **Exit 0** (the `devflow preflight: all dependencies present.` line) — the local tier is ready to run; nothing to report.
- **Non-zero exit** (one or more `devflow preflight: …` lines on stderr — a `missing required tool`, `PyYAML not found`, or `Python 3.11+ required` gap) — relay it to the user verbatim and tell them to install the gap themselves before running `/devflow:implement` or `/devflow:review`. For the common case (PyYAML missing), the fix is `python3 -m pip install -r requirements.txt` (preflight also prints its own `pip install pyyaml` hint). **Do not run `pip` for them** and **do not treat this as an init failure** — the config was still scaffolded.

There is **no trigger label** to create: in the cloud tier, `/devflow:implement` is started by commenting a bare `/devflow:implement <#>` on the issue (a native user event) — not by applying a label. The sender must be an allowed bot or an `allowed_users` collaborator with write access.

If the scaffolder exits non-zero (exit 2 = templates not found next to the script), the plugin install is incomplete. Tell the user to reinstall/update the DevFlow plugin (or run `install.sh` for the cloud tier). **Do not fall back to hand-writing the files** — that reintroduces exactly the drift this skill exists to prevent.

## Finally: advisory project-memory check (CLAUDE.md)

Config is scaffolded and the preflight has run, so init has **already succeeded** — this last step is a purely **advisory project-memory check** that **never creates, writes, or edits** `CLAUDE.md` (or any agent-instruction file) and **never blocks or fails init** regardless of what it finds. A repo with no `CLAUDE.md` gives DevFlow's automations no project memory, so `/devflow:review` and `/devflow:implement` run without the conventions, gotchas, and architecture notes that materially improve their output — and new adopters (the people running `/devflow:init`) are the ones most likely to be missing it. Surface that gap once, here, without ever touching a file.

Resolve the repo root and probe for the relevant files using only `git rev-parse --show-toplevel` and POSIX `test -f` (no GNU-only flags, so macOS/BSD behave identically):

```bash
ROOT="$(git rev-parse --show-toplevel)"
# CLAUDE.md detection is repo-root only (nested package-level or ~/.claude files are out of scope).
[ -f "$ROOT/CLAUDE.md" ] && echo "claude-md: present" || echo "claude-md: absent"
# AGENTS.md is matched CASE-INSENSITIVELY by testing the common forms (covers
# agent.md / agents.md) rather than reaching for a GNU-only `find -iname`. A
# case-insensitive filesystem (macOS) makes EVERY form's `test -f` match the one
# physical file, so report AGENTS.md AT MOST ONCE (first matching casing wins) —
# never one nudge per casing.
agents_seen=
for f in "AGENTS.md" "agents.md" "AGENT.md" "agent.md"; do
  [ -f "$ROOT/$f" ] && { [ -n "$agents_seen" ] || echo "agent-file: $f"; agents_seen=1; }
done
# The remaining files have a single canonical casing — no dedup needed.
for f in ".github/copilot-instructions.md" "GEMINI.md" ".cursorrules"; do
  [ -f "$ROOT/$f" ] && echo "agent-file: $f"
done
```

The `@`-import paths you cite are **repo-root-relative**, matching how Claude Code resolves `CLAUDE.md` imports — `@AGENTS.md`, `@.github/copilot-instructions.md`, `@GEMINI.md`, `@.cursorrules`. When `CLAUDE.md` is present, check **every** detected agent file the same loop-driven way (don't hand-pick one) — for each existing file, grep `CLAUDE.md` for its `@`-path and treat a miss as an unreferenced file:

```bash
for f in <each agent file detected above>; do
  grep -qF "@$f" "$ROOT/CLAUDE.md" || echo "unreferenced: @$f"
done
```

Compose output per this four-case matrix, and **say nothing when nothing is actionable** (so successful re-runs stay clean):

- **No `CLAUDE.md`, no detected agent file** → emit exactly **one** nudge: recommend the built-in `/init` command to create a `CLAUDE.md`, noting that project memory improves DevFlow's review/implement results. (Say nothing about `@`-imports — there is nothing to reuse.)
- **No `CLAUDE.md`, one or more detected agent files present** → the same nudge to the built-in `/init`, **plus** name each existing file and tell the user to reference it from the new `CLAUDE.md` via its `@`-import path (e.g. "you already have `AGENTS.md` — reference it with `@AGENTS.md`"). Emit **one** nudge per *physical* file — the detection above already collapses AGENTS.md's case-variants to a single entry, so never cite the same file under several casings.
- **`CLAUDE.md` present but it does not already reference an existing detected agent file** → suggest adding that file's `@`-import to `CLAUDE.md` (name the file and its `@`-path); no `/init` nudge.
- **`CLAUDE.md` present and it already references each existing detected agent file via `@`-import (or no such files exist)** → produce **no project-memory output** at all.

Remember: the built-in `/init` is a *different* command from `/devflow:init` (it lives in Claude Code itself) — recommend it, but never run it on the user's behalf here. The whole step is a relay, exactly like the preflight branch above.
