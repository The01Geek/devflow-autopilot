# Contributing to DevFlow

Thanks for your interest in improving DevFlow! This guide covers the basics.

## Repository layout

DevFlow is a single Claude Code plugin published at the repository root:

```
.claude-plugin/   plugin.json + marketplace.json (manifests)
skills/           the /devflow:implement, /devflow:review, /devflow:docs, … skills (SKILL.md each)
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
  resolve regardless of install location. Never hardcode `.devflow/vendor/devflow/…`
  in a skill (the cloud-tier *workflows* are the one exception — see below).
- **Portability:** avoid GNU-only flags. Use `python3` for date math (not `date -d`)
  and ERE / `sed -E` (not `grep -P`).
- **Windows / non-UTF-8 hosts.** The helpers self-defend at two layers: a committed
  `.gitattributes` pins every `*.sh`/`*.py`/`*.jq` to `eol=lf` on checkout (so
  `core.autocrlf=true` can't turn a shebang into `bash\r`), and every first-party
  `scripts/*.py` forces its own `stdout`/`stderr` and `gh` I/O to UTF-8 (so an em-dash
  or emoji can't trip a cp1252 codec). Two caller-side traps remain the contributor's
  responsibility on Windows, because they corrupt output **after** the helper ran
  cleanly:
  - **bash file-association.** Invoking a `.sh` via the `git-bash.exe --no-cd "%L"`
    file association (e.g. from PowerShell) can capture no stdout while exiting 0 —
    invoke `bash` explicitly with a POSIX path (`bash scripts/foo.sh`), never rely on
    the `.sh` double-click / file-association launcher.
  - **PowerShell 5.1 `>` / `Out-File`.** These re-encode captured stdout to UTF-16LE
    (a `FF FE` BOM + interleaved null bytes), which was the original cause of
    workpad-comment corruption. Capture helper output from a UTF-8 shell (Git Bash,
    WSL, `pwsh` 6+), or use `cmd /c "... > file"` / an explicit UTF-8-no-BOM write —
    **never** PowerShell 5.1 `>` or `Out-File`.

  If you already checked out the tree under `core.autocrlf=true` before `.gitattributes`
  existed, renormalize once with `git add --renormalize .` (or re-clone) — `.gitattributes`
  governs future checkout/normalization, not a tree that is already CRLF on disk.
- **No secrets, owner-specific IDs, or product names** in committed files. Config
  lives in `.devflow/config.json` (created from the example), which is gitignored.
- New `.py`/`.sh` files carry an SPDX header:
  ```
  # SPDX-FileCopyrightText: 2026 Daniel Radman
  # SPDX-License-Identifier: MIT
  ```
- **Every `skills/*/SKILL.md` carries the standardized consumer prompt-extension
  step.** As a preflight, each skill invokes
  `${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh <skill-name>` and honors
  any returned text as instructions appended verbatim to the end of its own prompt — the
  consumer-owned, upgrade-safe `.devflow/prompt-extensions/<skill-name>.md` (absent or
  empty → no-op). When you **add a new skill**, copy this step verbatim (substituting the
  new skill's directory name) so it inherits the convention, **and** add the new skill's
  name plus a one-line hint to the prompt-extension scaffold list in
  `scripts/scaffold-config.sh` — `/devflow:init` scaffolds one inert
  `<skill-name>.md.example` per skill, so a new skill needs a matching example. Two
  coverage tests in `lib/test/run.sh` enforce both halves: one enumerates every
  `skills/*/SKILL.md` and fails if a skill omits the standardized step, and the
  prompt-extension scaffold test derives the expected example set from `skills/*/` and
  fails if the scaffolder's list forgets one.

## Cloud-tier workflows

The `.github/workflows/*.yml` files run inside GitHub Actions, where they reference
plugin scripts at `.devflow/vendor/devflow/scripts/…`. That path assumes the cloud
tier is used with the plugin **vendored** into the consuming repo at that path (see
`docs/cloud-setup.md`). This is intentional and distinct from the local skills, which
use `${CLAUDE_SKILL_DIR}`.

## Submitting changes

1. Branch, make focused changes, run `bash lib/test/run.sh`.
2. Open a PR with a clear description. Update `CHANGELOG.md` under an `Unreleased` heading.
3. Be kind in review (see `CODE_OF_CONDUCT.md`).
