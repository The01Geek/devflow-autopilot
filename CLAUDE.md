# DevFlow — project memory

DevFlow is a single [Claude Code](https://code.claude.com) plugin published at the repo root; the repo is also its own marketplace. It turns a GitHub issue into a reviewed, documented, merged PR, and a weekly retrospective loop improves the automation. Full system reference: [`docs/DEVFLOW_SYSTEM_OVERVIEW.md`](docs/DEVFLOW_SYSTEM_OVERVIEW.md). Contributor guide: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Commands

```bash
bash lib/preflight.sh      # verify git/gh/jq/python3.11+/PyYAML on PATH
bash lib/test/run.sh       # full suite: jq filters + shell helpers + python; gh-stubbed, no network/auth
git ls-files '*.sh' | grep -v '^lib/test/' | xargs -r shellcheck --severity=warning -e SC1091
git ls-files '*.py' | xargs -r ruff check
```

CI (`.github/workflows/ci.yml`) runs the same suite + lint on every PR. The **required** status check is the job name **`lib + python tests`** (not "CI", which is the workflow name and never resolves).

## Architecture

- `skills/` — one `SKILL.md` per command (`/devflow:implement`, `/devflow:review`, `/devflow:review-and-fix`, the `/devflow:docs` family, `/devflow:create-issue`, `/devflow:retrospective-weekly`, …).
- `agents/` — review-engine subagents: `checklist-generator` (opus), `checklist-deduper` (sonnet), `checklist-verifier` (sonnet).
- `scripts/` — Python + shell CLIs (`workpad.py`, `config-get.sh`, `match-deferrals.py`, `file-deferrals.py`, `parse-acs.py`, `resolve-*-trigger.sh`, …).
- `lib/` — retrospective-loop helpers (`*.sh`, `*.jq`), `preflight.sh`, `test/`.
- `.github/` — optional cloud tier: workflows + composite actions (incl. `vendor-plugin`).
- `.devflow/` — `config.example.json` + `config.schema.json` (+ tracked `learnings/`, `logs/`). The live `config.json` is gitignored.

## Gotchas (load-bearing — easy to get wrong)

- **Skills locate bundled helpers via `${CLAUDE_SKILL_DIR}/../../<dir>/…`, NEVER `${CLAUDE_PLUGIN_ROOT}`** (not substituted inside `SKILL.md` bodies). The cloud-tier **workflows** are the one exception: they use the literal vendored path `.devflow/vendor/devflow/scripts/…`.
- **Config is `.devflow/config.json` (JSON), read by a Node resolver** (`config-get.sh` / `config-source.sh`), **not** Python. PyYAML is required only because `match-deferrals.py` / `workpad.py` parse YAML blocks embedded in PR/issue bodies. Renaming a config key? grep `.py`, `.sh`, `.yml`, and jq lines — silent-fail consumers exist (`match-deferrals.py`, `workpad.py`).
- **The review engine is shared.** `/devflow:review` Phases 0–4.3 are executed *verbatim* by `/devflow:review-and-fix` (which adds the fix loop + shadow pass and skips Phase 4.4). Edit `skills/review/SKILL.md`; never paraphrase the engine into the fix-loop skill.
- **Partition invariant with Anthropic's Claude app.** Every DevFlow trigger `if:` negates `@claude`, so DevFlow and the stock `claude.yml` never double-fire. Tests in `lib/test/run.sh` enforce this. Never create/overwrite `claude.yml`. Triggers fire on real *comments* only — never issue/PR bodies or titles.
- **Cloud allowlist needs the helper as the command's LEADING token.** No `VAR=value` prefix, no `bash <path>` wrapper — otherwise the read-only `review` profile silently denies it (overrides/telemetry resolve to empty). Invoke `config-get.sh`/`efficiency-trace.sh`/`resolve-review-overrides.py` directly by path.
- **Vendor to `.devflow/vendor/devflow/`, never `.claude/`.** `claude-code-action` `rm -rf`s sensitive paths (incl. `.claude/`) and restores them from the *base* branch before installing plugins, which would wipe a plugin vendored under `.claude/`.
- **The exclusion list in `lib/check-excluded-path.sh` and the copy in `skills/retrospective-audit/SKILL.md` must stay in sync.**
- **Embedded `jq '…'` programs are inside bash single quotes — keep their `#` comments apostrophe-free ASCII.** `scripts/scaffold-config.sh` carries multi-line jq programs; an ASCII `'` (e.g. `user's`) terminates the bash string (shellcheck **SC1073/SC1011** + test failures), and a curly `'` trips **SC1112** (CI's lint job fails on it). Reword to avoid contractions. Same trap: `startswith`/string ops on a possibly-non-string field abort the *whole* filter — guard with `(.x | strings)` and type-check before indexing (`(.a | type) == "object"`).
- **Editing a best-effort parser (`scaffold-config.sh`, `config-get.sh`, the jq/`config.json` consumers)? Lead with an adversarial input-shape matrix, not the happy path.** These run on configs a human can hand-corrupt, so the bug class is "a shape detonates the filter or yields a misdirected/silent breadcrumb." Enumerate the finite matrix up front — `{top-level, devflow_review, agent_overrides, a value, model}` × `{object, array, scalar, missing, wrong-type}` — and add a `run.sh` block asserting *exit-0 + a specific (not generic) breadcrumb* for each. One deterministic sweep beats finding these one-at-a-time across review iterations.
- **`DevFlow` is the reserved provenance label — retrospective detection is label-first, not branch-prefix-first.** DevFlow stamps the literal `DevFlow` label (a hardcoded constant — no config key controls it; `docs.labels` is the *separate* docs-pass label, default `Documented`) on every issue/PR it creates, via the idempotent best-effort `scripts/ensure-label.sh <name>` (always exits 0). `lib/scan.sh` selects a PR via a **union predicate** — (a) the `DevFlow` label (author/branch-agnostic), (b) a watched author that **closes an issue** (`closingIssuesReferences` non-empty — the branch-naming-independent fallback), (c) `devflow/audit-*`, (d) `implementation_branch_prefix` *only when set non-empty* (empty ≠ match-all). Don't reintroduce a branch-prefix-only predicate; it silently no-ops on any bot whose branches don't match the prefix.
- **The workpad lives on the ISSUE, not the PR thread.** `lib/fetch-pr-context.sh` reads the `<!-- devflow:workpad -->` comment (and its `## Devflow Reflection` bullets → `reflections[]`, and final Status → `workpad_final_status`) from the **issue** comments — detect it by marker, never by author (it's authored by github-actions). Reading it from the PR conversation thread (the old bug) leaves those fields ~always empty and makes `cheap-gate.jq`'s workpad/reflection checks inert. Strip the status glyph (🚀/🎉/👎) to the bare word (`🎉 Complete` → `Complete`); a non-empty `reflections[]` forces LLM analysis even when every other signal is clean.
- **Versioning is repo-policy, kept OUT of the engine.** `/devflow:implement` is versioning-agnostic; DevFlow manages its own version through its consumer prompt extension `.devflow/prompt-extensions/implement.md` — **edit that extension, not the skill**, to change the rule. Load-bearing constants kept here because CI depends on them: a `version` bump in `.claude-plugin/plugin.json` REQUIRES a matching `CHANGELOG.md` entry in the same change or the Phase 3 review gate FAILs; internal-only changes (tests, CI, dev-only docs) don't bump; the default increment is **`patch`** (`minor`/`major` only when the issue explicitly authorizes it).

## Conventions

- **Portability:** no GNU-only flags. Use `python3` for date math (not `date -d`) and ERE / `sed -E` (not `grep -P`). Helpers must work on macOS/BSD without GNU coreutils.
- **No secrets, owner-specific IDs, or product names in committed files.**
- New `.py`/`.sh` files carry the SPDX header (`SPDX-FileCopyrightText: 2026 Daniel Radman` / `SPDX-License-Identifier: MIT`).
- Docs reference bare source paths (`scripts/workpad.py`), never `path:line` — line numbers rot.
- **Marketing/positioning copy** (`README.md`, `docs/DEVFLOW_SYSTEM_OVERVIEW.md`) leads with the wedge — *out-of-the-box agentic coding works on pet projects but can't complete a real ticket in a large production codebase; DevFlow makes it ship*. Honor the honest-claims guardrails (review-ready, **not** auto-merged; shadow review **narrows, never closes** the gap). §21 is the messaging source of truth.
- Don't push to `main` from an agent; the classifier blocks `git push origin main`. Inside `/devflow:implement` & `/devflow:review-and-fix` there is standing permission to auto-commit+push to the *feature* branch.
