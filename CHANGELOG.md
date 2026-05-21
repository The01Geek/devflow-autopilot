# Changelog

All notable changes to DevFlow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
