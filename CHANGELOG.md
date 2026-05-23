# Changelog

All notable changes to DevFlow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.3] — 2026-05-22

### Added
- **Automatic `devflow:implement` label creation.** `install.sh` (cloud tier) and `/devflow:init` (local tier) now create the trigger label in the repo if it's missing — best-effort, via `gh`, so a missing/unauthenticated `gh` just prints a hint instead of failing setup. Honours `claude_implement.trigger_label`.
- **End-to-end workflow walkthrough** in the README — issue → label → autonomous implement → review → docs → PR — so the full loop is demonstrated in one place.

### Changed
- **`/devflow:implement` now triggers on a bare `/devflow:implement <#>`** — comment, review, or issue body/title — with **no `@claude` required**. `claude-implement.yml` runs claude-code-action in agent mode with a synthesised prompt and gates on a new authorization step (`scripts/resolve-implement-trigger.sh`: allowed bot or write/admin/maintain collaborator). Because a stock `claude.yml` only fires in tag mode on `@claude`, the two workflows can no longer double-fire on the bare command — and **installing the plugin no longer requires editing an adopter's `claude.yml`**. The `devflow:implement` label path is unchanged. `@claude /devflow:implement <#>` still works.
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
