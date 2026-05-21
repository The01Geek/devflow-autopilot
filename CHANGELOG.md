# Changelog

All notable changes to DevFlow are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
