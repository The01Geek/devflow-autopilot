# Contributing to DevFlow

Thanks for your interest in improving DevFlow! This guide covers the basics.

## Repository layout

DevFlow is a single Claude Code plugin published at the repository root:

```
.claude-plugin/   plugin.json + marketplace.json (manifests)
skills/           the /implement, /review, /docs, … skills (SKILL.md each)
agents/           subagent definitions
lib/              shell + jq helpers for the retrospective loop, plus lib/test/
scripts/          Python + shell CLIs (workpad.py, config-get.sh, …)
.github/          the optional "cloud tier" workflows + composite actions
docs/             cloud-setup guide and other docs
```

## Prerequisites

- `git`, `gh` (GitHub CLI, authenticated), `jq`
- Python 3.11+ with PyYAML (`python3 -m pip install -r requirements.txt`)

Run `bash lib/preflight.sh` to verify your environment.

## Running the tests

```bash
bash lib/test/run.sh
```

This runs the jq-filter tests, the shell-helper tests, and the Python script
tests (`lib/test/test_python_scripts.py`). CI runs the same suite on every PR
(`.github/workflows/ci.yml`). Tests use `gh` **stubs** — no network or GitHub
auth is required to run them.

## Conventions

- **Skills reference bundled files via `${CLAUDE_SKILL_DIR}/../../<dir>/…`** so they
  resolve regardless of install location. Never hardcode `.claude/plugins/devflow/…`
  in a skill (the cloud-tier *workflows* are the one exception — see below).
- **Portability:** avoid GNU-only flags. Use `python3` for date math (not `date -d`)
  and ERE / `sed -E` (not `grep -P`).
- **No secrets, owner-specific IDs, or product names** in committed files. Config
  lives in `.github/project-config.yml` (created from the example), which is gitignored.
- New `.py`/`.sh` files carry an SPDX header:
  ```
  # SPDX-FileCopyrightText: 2026 Daniel Radman
  # SPDX-License-Identifier: MIT
  ```
- The exclusion list in `lib/check-excluded-path.sh` and the copy in
  `skills/audit-implementations/SKILL.md` must stay in sync.

## Cloud-tier workflows

The `.github/workflows/*.yml` files run inside GitHub Actions, where they reference
plugin scripts at `.claude/plugins/devflow/scripts/…`. That path assumes the cloud
tier is used with the plugin **vendored** into the consuming repo at that path (see
`docs/cloud-setup.md`). This is intentional and distinct from the local skills, which
use `${CLAUDE_SKILL_DIR}`.

## Submitting changes

1. Branch, make focused changes, run `bash lib/test/run.sh`.
2. Open a PR with a clear description. Update `CHANGELOG.md` under an `Unreleased` heading.
3. Be kind in review (see `CODE_OF_CONDUCT.md`).
