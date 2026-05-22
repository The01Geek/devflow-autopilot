# Changelog

All notable changes to DevFlow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
