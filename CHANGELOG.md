# Changelog

All notable changes to DevFlow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.2] — 2026-05-23

### Added
- **Early-acknowledgement reaction.** The moment a `/devflow:*` command is authorized and resolvable, the `gate` job adds a 🚀 reaction to the triggering comment (or, for a `/devflow:implement` issue body/title, the issue itself) via `scripts/react-to-trigger.sh` — so requesters see the trigger was picked up well before the heavy `claude`/`command` job spins up. It is best-effort: the script always exits 0 and the step is `continue-on-error: true`, so a failed or forbidden reaction never blocks the run. A `/devflow:*` submitted as a PR *review* gets no reaction (GitHub exposes no reactions API for reviews). The `gate` job's token gains `issues: write` + `pull-requests: write` for the reactions POST.

## [2.2.1] — 2026-05-22

### Changed
- **DevFlow now owns its own workflow files and never touches `claude.yml`.** `claude.yml` is generated and owned by Anthropic's Claude GitHub App; DevFlow used to commandeer that filename. The light `@claude`-mention listener (`claude.yml`) and the reusable runner (`claude-runner.yml`) are merged into a single DevFlow-owned **`devflow.yml`** — one file with two roles, selected by whether `inputs.prompt` is set: the reusable `workflow_call` runner (called by `devflow-review.yml`) and the bare-`/devflow:*` command listener. `claude-implement.yml` → **`devflow-implement.yml`**.
- **Triggering moved to bare `/devflow:*` commands; `@claude` is ceded to Anthropic.** Every DevFlow trigger now negates `@claude`, so `@claude` mentions (plus generic Q&A and `/security-review`) route only to Anthropic's `claude.yml`, and bare `/devflow:review` · `/devflow:pr-description` · `/devflow:review-and-fix` · `/devflow:implement <#>` route only to DevFlow. No comment can double-fire both. The light commands now run in AGENT mode via a new `scripts/resolve-command-trigger.sh` (sharing the authorization gate with the implement path through the new `scripts/authorize-actor.sh`).
- **`install.sh`** ships `devflow.yml` / `devflow-implement.yml` / `devflow-review.yml` and, on upgrade, removes a repo's superseded DevFlow-authored `claude*.yml` — signature-guarded so a genuine Anthropic-owned `claude.yml` is left untouched.

### Added
- **`claude.allowed_users` config** (string, comma-separated logins or `"*"`, default `"*"`). A repo can restrict which human logins may trigger DevFlow workflows. It is an AND-filter on top of the existing write/admin/maintain collaborator check — it can only tighten the gate, never bypass it. Bots remain governed separately by `claude.allowed_bots` (the path for a custom GitHub App that posts the trigger comment).

### Removed
- **The `devflow:implement` label trigger.** A bare `/devflow:implement <#>` comment — itself a native, no-App user event — is now the sole trigger. The `claude_implement.trigger_label` config key, the label-creation step in `scaffold-config.sh`, and the `IS_LABEL_EVENT` resolver path are gone.
- **Migration:** re-run `install.sh` (or `/devflow:init`) to install the renamed workflows; it removes the old DevFlow `claude.yml` / `claude-runner.yml` / `claude-implement.yml` automatically. If you installed Anthropic's Claude GitHub App, its `claude.yml` is preserved and now owns `@claude`. Drop the `claude_implement.trigger_label` key from `.devflow/config.json` (the label is no longer used); trigger implementation by commenting `/devflow:implement <#>` instead of applying a label.

## [2.2.0] — 2026-05-22

### Changed
- **Naming consistency.** Command references now use the `devflow:`-namespaced form (`/devflow:implement`, `/devflow:review`, `/devflow:init`, …) throughout the docs and skills — `/review`, `/init`, and `/security-review` collide with built-in Claude Code commands, so the bare forms are ambiguous. The `implement` skill's trigger description now names the real trigger (`/devflow:implement`) instead of a bare `/implement`.
- **Unified the retrospective family naming.** Renamed `audit-implementations` → `retrospective-audit` and `devflow-weekly` → `retrospective-weekly`, so the whole self-improvement loop reads as one family: `retrospective-weekly` (orchestrator) + `retrospective` (Stage A, per-PR) + `retrospective-audit` (Stage B, per-pattern). The orchestrator is now invoked as `/devflow:retrospective-weekly` (dropping the redundant `/devflow:devflow-weekly`). The `dismissed_by` provenance label written to `overrides.json` follows the new name.
- **Renamed `lib/conf.sh` → `lib/config-source.sh`** — clearer that it's a sourced bash helper (it reads as a config *file* otherwise), and it now pairs obviously with the `config-get.sh` resolver. The `devflow_conf` function name is unchanged.
- **Review scratch consolidated under `.devflow/tmp/`.** `/devflow:review` and `/devflow:review-and-fix` now write their cached diff, per-iteration workpads, and deferrals manifest to `.devflow/tmp/review/<slug>/` (was `.devflow/review/<slug>/`). This puts **all** ephemeral run state under the single `.devflow/tmp/` scratch root, so one scoped ignore covers everything. Functionally identical in GitHub Actions (same workspace within a run; cross-run deferral handoff goes through the PR body, not the file).
- **Scoped scratch ignore for adopters.** `scaffold-config.sh` (run by both `install.sh` and `/devflow:init`) now writes a `.devflow/.gitignore` that ignores **only** `tmp/` — created only when absent. `config.json` (which the cloud tier must read from the committed tree), `learnings/` (retrospectives), and the schema/example stay tracked. The `.devflow/` root is never blanket-ignored.
- **Inlined the `dedupe-pr-events` composite action.** Deleting `sync-pr-status-to-issue.yml` left `devflow-review.yml` as its only caller, and its ~8 lines of bot/event-variant detection were already mirrored inline in that workflow's `route` step. Folded the logic into `route` and deleted `.github/actions/dedupe-pr-events/` (and its entry in `install.sh`'s action-copy loop), so the bot-detection lives in exactly one place.
- **Extracted a `setup-project-env` composite action.** The ~54-line runtime-provisioning block (Python / Node / pip cache / `setup.install` deps) was copy-pasted verbatim across `claude.yml` and `claude-implement.yml` with a "change both together" comment. Moved it into `.github/actions/setup-project-env` (takes the config JSON as input); both workflows now call it, so the provisioning logic has one source of truth. Added to `install.sh`'s action-copy loop.

### Removed
- **GitHub Project board automation.** Deleted `move-to-in-progress.yml`, `sync-pr-status-to-issue.yml`, and `close-released-items.yml` — the three workflows that moved Project (ProjectV2) board cards between columns. They were opt-in (off by default) and orthogonal to DevFlow's core `/devflow:implement` · `/devflow:review` · `/devflow:docs` flow. With them gone, the `project_number`, `statuses`, `bot_login`, and `cloud_secrets` config fields and the `workflows.{move-to-in-progress,sync-pr-status-to-issue,close-released-items}` toggles are dropped from the schema and example.
- **`PROJECT_PAT` requirement.** The three board workflows were its only consumers, so the entire Classic-PAT story is retired: the `cloud_secrets` secret-name remap step in `install.sh`, the "Custom secret names" / "Project board" sections and `PROJECT_PAT` rows in `docs/cloud-setup.md`, and the `SECURITY.md` mention are all removed. The cloud tier now needs only `CLAUDE_CODE_OAUTH_TOKEN`.
- **Config placeholders.** `project_number` was the only `YOUR_*` placeholder; with it gone, the scaffolded `.devflow/config.json` is usable as-is on built-in defaults. The "fill in the placeholders" guidance in `install.sh`, `scaffold-config.sh`, `/devflow:init`, and `docs/cloud-setup.md` is updated to "edit only to customize."
- **Orphaned `security_audit` config.** Removed the `security_audit` config block and the `workflows.security_audit` toggle from the schema/example, plus the `security-audit` entry in the `install.sh` copy loop. No `security-audit.yml` workflow ever shipped and nothing read these keys — they were dead scaffolding for an unbuilt feature.
- **Migration:** if you used the board sync, the three workflow files, the `PROJECT_PAT` secret, and the `project_number` / `statuses` / `bot_login` / `cloud_secrets` config keys can be deleted from your repo. The `read-project-config` composite action is unaffected (still used by the `@claude` / implement / review workflows); `dedupe-pr-events` was inlined into `devflow-review.yml` and its directory removed (see "Inlined the `dedupe-pr-events`…" above).

## [2.1.3] — 2026-05-22

### Added
- **Automatic `devflow:implement` label creation.** `install.sh` (cloud tier) and `/devflow:init` (local tier) now create the trigger label in the repo if it's missing — best-effort, via `gh`, so a missing/unauthenticated `gh` just prints a hint instead of failing setup. Honours `claude_implement.trigger_label`.
- **End-to-end workflow walkthrough** in the README — issue → label → autonomous implement → review → docs → PR — so the full loop is demonstrated in one place.

### Changed
- **`/devflow:implement` now triggers on a bare `/devflow:implement <#>`** — comment, review, or issue body/title — with **no `@claude` required**. `claude-implement.yml` runs claude-code-action in agent mode with a synthesised prompt and gates on a new authorization step (`scripts/resolve-implement-trigger.sh`: allowed bot or write/admin/maintain collaborator). Because a stock `claude.yml` only fires in tag mode on `@claude`, the two workflows can no longer double-fire on the bare command — and **installing the plugin no longer requires editing an adopter's `claude.yml`**. The `devflow:implement` label path is unchanged. `@claude /devflow:implement <#>` still works; on that redundant form `claude-implement.yml` posts a one-line reminder nudging users toward the bare command. `claude.yml` is not edited at all — its existing `@claude`-exclusion clause continues to keep the redundant form from double-firing a Claude run.
- **`/devflow:implement` is now triggered by a label, not a bot comment.** Adding the **`devflow:implement`** label (configurable via `claude_implement.trigger_label`) to an issue starts the implementation lifecycle. `claude-implement.yml` gained an `issues: [labeled]` trigger and synthesises the command via an explicit `prompt`; the `@claude /devflow:implement <#>` comment/issue-body path is unchanged. Because a human label-add is a real user event, it triggers Actions natively — removing the entire GitHub App requirement (see Removed).

### Removed
- **GitHub App dependency.** Deleted `comment-on-draft-issues.yml` and the `get-app-token` composite action — the only consumers of the App. The `DEVFLOW_APP_ID` / `DEVFLOW_APP_PRIVATE_KEY` secrets, the `app_id` config field, the `cloud_secrets.app_id` / `cloud_secrets.app_private_key` overrides, and the `workflows.comment-on-draft-issues` toggle are gone. The cloud tier now needs only `CLAUDE_CODE_OAUTH_TOKEN` (plus `PROJECT_PAT` if you use a project board). Also dropped the vestigial `app_id` output from `move-to-in-progress.yml` and `close-released-items.yml` (read but never used; both authenticate with `PROJECT_PAT`).
- **`statuses.draft` config field.** Its only consumer was `comment-on-draft-issues.yml`; with that workflow gone, nothing reads a `draft` board status, so the field is dropped from the schema and example. (The fully-automatic "issue lands in the board's Draft column → auto-implement" path is replaced by adding the `devflow:implement` label.)
- **Migration:** create a `devflow:implement` label in your repo and add it to issues you want implemented (or keep commenting `@claude /devflow:implement <#>`). The App secrets and `app_id` / `comment-on-draft-issues` / `statuses.draft` config keys can be deleted.

## [2.1.1] — 2026-05-22

### Added
- **`/devflow:init`** — a one-time setup command (hidden from model auto-invocation via `disable-model-invocation`, so it adds zero per-turn context cost) that scaffolds `.devflow/config.json` from the shipped template **only if absent** and refreshes `config.schema.json`. It resolves templates from the installed plugin, so it works on a marketplace install where the templates aren't in the repo — unlike the old `cp .devflow/config.example.json …`, which only worked from the source repo.
- **`scripts/scaffold-config.sh`** — the single shared config scaffolder. Both `/devflow:init` and `install.sh` call it, so local- and cloud-tier scaffolding can never drift; they coexist safely (no-clobber, schema-only refresh on re-run regardless of order).

### Changed
- `install.sh` step 5 now delegates to `scaffold-config.sh` (behaviour unchanged: never clobbers `config.json`, always refreshes the schema) and vendors the two config templates into the plugin so the vendored `/devflow:init` can find them.

## [2.1.0] — 2026-05-22

### Added
- **Config-driven `@claude` tool allowlist.** New `claude.allowed_tools` and `claude_implement.allowed_tools` arrays append repo-specific `--allowed-tools` entries (claude-code-action syntax, e.g. `Bash(make:*)`) on top of DevFlow's built-in base list — no workflow YAML editing. The two keys are independent: the implement path does not inherit the light path's extras. Documented in `docs/cloud-setup.md`.
- **`/create-issue` confirmation gate.** New Step 4 renders the full assembled issue and waits for the user's explicit approval before `gh issue create` — the drafted ticket is never filed unseen. A gitignored `.devflow/tmp/issue-draft-<slug>.md` preview copy is written for editor review (never the posting source).

### Fixed
- **`/devflow:review` standalone runs no longer post a dangling pointer.** When run directly from an IDE/CLI (`$GITHUB_ACTIONS` unset), Phase 4.4 now puts the full report in the `gh pr review` body instead of a stub pointing at a progress comment that only the auto-trigger workflow creates.
- **`claude-runner.yml` grants `actions: read`** to match its `additional_permissions` input, so Claude's CI-result reads no longer 403 (the explicit `permissions:` block had defaulted the scope to `none`).

## [2.0.0] — 2026-05-22

### Changed
- **BREAKING — config is now `.devflow/config.json` (JSON), not `.github/project-config.yml` (YAML).** Adopters re-run `install.sh` to scaffold the new file; the old YAML path is no longer read (no fallback ships). The live config stays gitignored; a committed `config.example.json` + `config.schema.json` (with `$schema` for editor autocomplete/validation) replace the YAML template.
- **Both config-parser prerequisites dropped.** A single Node-based resolver (`scripts/config-get.sh`, which `lib/conf.sh` now delegates to) reads the config — config parsing no longer needs PyYAML (plugin tier) or yq (cloud tier). The `read-project-config` action validates with Node and passes the JSON through; the previously inline-yq board workflows now use that shared action. (Note: this scopes only the **config layer** — PyYAML is still a DevFlow prerequisite for other helpers, e.g. `match-deferrals.py`'s PR-body parsing.)
- `setup.install` is now a JSON **array of shell lines** (joined with newlines at runtime) instead of a YAML block scalar.

## [1.1.0] — 2026-05-21

### Added
- `/devflow:review-and-fix` — `--push-each-iteration` flag and a PR-mode head-override, so the fix loop reviews its own local commits and can propagate each iteration to the remote PR (and its CI). `/implement` Phase 3.3 sets the flag.
- `/docs-verify` — `--report-only` mode that returns a findings report without editing, committing, or pushing; `/create-issue` now uses it so issue creation never writes to a protected branch.
- `/implement` — 2.3.0 changed-contract and 2.3.4 boundary-assumption sweeps over the diff.
- GitHub Actions "cloud tier" `install.sh` — one-command install/update — plus configurable cloud-workflow runtime provisioning.
- GitHub autolink-hygiene guidance (no bare `#`+digit unless a real issue/PR reference) across the GitHub-writing skills.
- CI lint job (ruff blocking; shellcheck/actionlint provisional) and expanded Python/shell test coverage.

### Changed
- Command references namespaced to `/devflow:review` and `/devflow:review-and-fix` across docs and skills; the bare forms still resolve when there is no name collision.
- Install instructions add the `claude-plugins-official` marketplace first so cross-marketplace dependencies resolve; documented that PyYAML is not auto-installed by `/plugin`.
- Cloud workflow runs on `ready_for_review`; Node-20 action bumps and a `claude-runner` ref input.

### Fixed
- Root-level devflow plugin now uses the relative-path `./` source in `marketplace.json`.
- `meta-issue.sh` dead `--title` flag.

## [1.0.0] — 2026-05-19

First public release. Extracted into a standalone, generic plugin from its
original home in a private product repository.

### Added
- `/implement` — 4-phase issue-to-PR orchestrator (setup → implement → review → docs).
- `/review` and `/devflow:review-and-fix` — verification-checklist review engine (report-only and auto-fixing).
- `/docs` suite — `docs-sync-internal`, `docs-sync-external`, `docs-bootstrap-internal`, `docs-bootstrap-external`, `docs-verify`, `docs-release-notes`.
- `/create-issue` and `/pr-description`.
- Self-improving retrospective loop — `/devflow-weekly`, `/retrospective`, `/audit-implementations`.
- Optional GitHub Actions "cloud tier" (autonomous issue/PR automation) — see `docs/cloud-setup.md`.
- Auto-installed plugin dependencies: `feature-dev`, `pr-review-toolkit`, `superpowers` (from `claude-plugins-official`).

### Notes
- The local tier (the in-editor skills) works with **no configuration**; every config value has a built-in default.
- Helper scripts reference their bundled location via `${CLAUDE_SKILL_DIR}`, so the plugin works from any install location.
- Shell helpers avoid GNU-only flags (`date -d`, `grep -P`), so the retrospective loop runs on macOS/BSD as well as Linux.
