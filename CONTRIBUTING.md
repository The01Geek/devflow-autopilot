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

**Windows (stock Python): resolving `python3`.** A stock Windows Python install (python.org / `winget install python`) puts Python on PATH as `python` and the `py -3` launcher — there is **no `python3`**, so every DevFlow helper and the agent-typed `python3 <path>` calls fail. When `python3` is absent but a `>=3.11` Python is reachable as `python` or `py -3`, run the consent-gated provisioner to install a small `python3` shim onto your PATH:

```bash
bash scripts/provision-python3-shim.sh --apply
```

It picks the first of `python3`/`py -3`/`python` reporting `>=3.11`, writes a `python3` that forwards to it (a no-op when a real `python3 >=3.11` already resolves), and prints a `devflow-python:` breadcrumb. macOS/Linux already have a real `python3`, so this is a no-op there. `bash lib/preflight.sh` points you here when it detects the no-`python3`/has-alternate state.

## Running the tests

```bash
bash lib/test/run.sh
```

This runs the jq-filter tests, the shell-helper tests, and the Python script
tests (`lib/test/test_python_scripts.py`). CI runs the same suite on every PR
(`.github/workflows/ci.yml`). Tests use `gh` **stubs** — no network or GitHub
auth is required to run them.

Some coverage is factored into **selectable modules** under `lib/test/modules/`
(registered in `scripts/workflow-flight-recorder-registry.json`), which you can run
in isolation while iterating on their area:

```bash
bash lib/test/run-module.sh create-issue-contract
```

Each module is also executed by the full suite through the fail-closed
`devflow_run_full_suite_module` boundary, and shares the namespaced pin helpers in
`lib/test/module-harness.sh` (`devflow_module_pin_count` / `pin_unique` /
`pin_present` / `pin_red_under`) so a module carries no private pin machinery.
A per-module inventory (e.g. `lib/test/modules/create-issue-contract.inventory.md`)
records what it covers.

#### Coverage-map block ownership (every PR that adds an assertion)

`lib/test/modules/coverage-map.json` is the ranked to-do list for future
extractions, and its `run_sh_blocks` half is **derived**, not curated. The coverage
guard (`lib/test/coverage_map_guard.py`, driven by the complete suite) derives the
issue labels asserted by `lib/test/run.sh` and by every `lib/test/modules/*.sh` —
anchored on assertion-name position, so a `#NNN` in a comment derives nothing — and
turns the suite RED when:

- a label asserted in `lib/test/run.sh` has **no** `run_sh_blocks` entry, or
- a **fully extracted** label — carried by a module and asserted nowhere in
  `lib/test/run.sh` — has no entry, or names `unmodularized` instead of a module
  that carries it.

So **any** PR that adds an assertion named for a new issue owes that label a map
entry, not only a PR that extracts a module. The remedy is mechanical — run it and
commit the result:

```bash
python3 lib/test/coverage_map_guard.py . --fix
```

`--fix` is **hand-invoked only**. It is deliberately not wired into the batched
generated-artifact pass, where the coverage map stays a `by-hand` judgment row whose
write-scope assertion proves the pass leaves the file byte-unchanged. Running it
twice in a row leaves the file byte-unchanged the second time, and it refuses to
write a malformed map rather than corrupting it.

A label a module carries while assertions remain in `lib/test/run.sh` is *partially*
extracted and correctly stays `unmodularized`: one `owner` string cannot truthfully
describe split coverage.

The arm is deliberately **one-directional**: it reports a label the tree asserts but the
map does not carry, never the reverse. A map entry with no derivation behind it — a
block whose assertions were deleted or renamed — is a curated historical record, so it is
neither reported nor removed by `--fix`. Prune such an entry by hand when you want it gone.

### Regenerating suite-owned artifacts

Several suite gates compare a checked-in generated artifact against what the tree
implies, so a source edit can turn the suite red until the artifact is refreshed.
Run one batched pass before re-running the suite:

```bash
python3 lib/test/regenerate-artifacts.py
```

It regenerates the one mechanically-safe artifact (the cloud-writer runtime manifest,
`scripts/devflow-cloud-writer-contract.json` — the only path it ever writes) and runs a
**non-writing** check for each judgment-gated artifact, reporting every judgment item
together in one pass instead of one red run at a time. The registry inside the helper is
the sole enumeration point — run `--list` for the current set rather than trusting a
copy here, which would go stale the next time an artifact is added. Judgment items are yours to resolve deliberately — the helper never
edits them. Exit codes: `0` clean, `1` action required, `2` infrastructure failure
(which wins over `1`). Use `--list` to see the registered artifacts and `--repo-root` to
point it at another checkout.

#### The registry is also the merge-conflict oracle

When a branch update lands a merge conflict in a checked-in **generated** artifact, do
not hand-merge its bytes: hand-merged bytes match no source of truth, so the artifact's
own suite gate then reports them as drift with a remedy aimed at the wrong file, while
silently reverting whatever the other side added. The same registry answers what to do
instead, via `--list`:

- `conflict-path <row> <path>` — the generated paths a conflict in that row can land in.
- `conflict-class <row> <class>` — one of `regenerate` (re-run the row's generator against
  the merged tree), `reconcile-source` (merge the *source* first, then regenerate), or
  `by-hand` (a genuine hand-merge is correct for this row).
- `conflict-recipe <row> <text>` — the row's governing policy, reused verbatim as the
  recipe so the batched pass's `governing policy:` output and this rule cannot drift.
- `conflict-sibling <row> <path> <class>` — a coupled path a row's conflict can also touch,
  governed by **that line's own** class (e.g. `lib/review-profile.tokens`, the reviewer
  security-boundary lock the capability generator never writes, is `by-hand`).

These four line kinds are emitted strictly *after* the existing `artifact` and
`budget-watch` lines, whose formats are byte-unchanged, so prefix-anchored consumers parse
as before. The rule is fail-closed at both ends: a conflicted path that is **not** among
the emitted `conflict-path`/`conflict-sibling` paths is an ordinary hand-merge, and a
`--list` that cannot run — or that emits no `artifact`/`conflict-class` lines — means
needs-human-reconciliation and stop, never a guessed hand-merge.

Autonomous `/devflow:implement`, `/devflow:review-and-fix`, and `/devflow:receiving-code-review`
runs apply this automatically: the rule lives, byte-identical, in the three
`.devflow/prompt-extensions/` files, and each skill's in-run conflict arm carries a generic
pointer to it. Adding a new artifact row therefore extends the conflict rule with no prompt
edit — the registry stays the sole enumeration point.

### Authoring a new focused module

When you extract a cohesive block of `lib/test/run.sh` coverage into a new
selectable module, complete all of the following in the same PR:

1. **Registry entry** — add the module to `test_modules` in
   `scripts/workflow-flight-recorder-registry.json` with its `path`,
   `minimum_assertions` floor, and a `description`.
2. **Floor from the extraction-time count** — establish the floor with the
   over-floor probe under the already-granted direct `lib/test/run.sh`
   invocation: set the registry and call-site floor to a deliberately over-high
   value, run the suite, read the boundary's below-floor line
   (`executed N assertions; minimum is M`) to obtain the true executed count `N`,
   then set the floor to `N` (the boundary's success path prints no count, so a
   floor seeded without the probe is unverified).
3. **Mirror the floor at the call site** — the same floor literal appears at the
   `run.sh` `devflow_run_full_suite_module` boundary call. The registry floor and
   the call-site literal are one coupled contract, cross-checked for every module
   by `lib/test/test_module_runner.py`.
4. **Per-module inventory** — add `lib/test/modules/<module-id>.inventory.md`
   recording the module's provenance (source baseline + coverage groups).
5. **CI shellcheck list** — add the module's `.sh` path to the explicit
   shellcheck file list in `.github/workflows/ci.yml` (module files are not
   globbed there).
6. **Coverage-map ownership** — update `lib/test/modules/coverage-map.json` so
   each `lib/`/`scripts/` depth-1 unit the module now owns names it as `owner`
   (the coverage ratchet, `lib/test/coverage_map_guard.py`, fails the suite RED
   on a stale, misfiled, or unlisted unit). If the ratchet fires on a code
   extension outside the five depth-1 patterns, extend the pattern set (a map +
   guard + this convention change in one PR) — never list a code file in
   `non_code_exempt`. The `run_sh_blocks` half is **derived and enforced** by the
   guard, not hand-maintained: it scans `lib/test/run.sh` and every
   `lib/test/modules/*.sh` at assertion-name position and fails RED on a `run.sh`
   label with no map entry, and on a **fully extracted** label (carried by a module,
   asserted nowhere in `run.sh`) whose entry is absent or still names
   `unmodularized`. A **partially extracted** label — one a module carries while
   assertions remain in `run.sh` — correctly keeps `unmodularized`, because a single
   `owner` string cannot describe split coverage. Repair the map with
   `python3 lib/test/coverage_map_guard.py . --fix` rather than by hand (see
   *Coverage-map block ownership* under Running the tests).
7. **Module-contract compliance** — the module must satisfy the module contract
   documented in `lib/test/module-harness.sh`'s header (private fixture root and
   cleanup, caller-provided `LIB`/`RESULTS_FILE`/`assert_eq`, no self-skip, no
   monolith helper). Comply **by reference** to that header — do not restate its
   cleanup/trap terms here, so this checklist cannot go stale as the contract
   evolves.

The suite reports passed, failed, and *skipped* tallies (issue
#456) — so `0 failed` is never mistaken for "everything ran." A check can
**self-skip** when the environment cannot run it or express its condition; with
nothing skipped the summary is byte-identical to before (`N passed, M failed`),
and with skips it reads `N passed, M failed, K skipped` followed by one line per
skipped check naming the check, its **kind** (`blocking-gate` for a real gate
that should have run here but could not, `host-capability` for a condition the
host cannot express), and the reason. The exit code is unchanged — a skip never
fails the suite. The summary renderer lives in `lib/test/summary.sh`.

## Conventions

- **Skills reference bundled files via the portable single-statement anchor
  `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../<dir>/…`** so they
  resolve regardless of install location and runner (`$CLAUDE_SKILL_DIR` on Claude Code;
  the runner-reported skill base directory substituted for the placeholder elsewhere —
  never assigned to a shell variable read by a later statement, which some runners'
  inline-bash marshaling drops). Never hardcode `.devflow/vendor/devflow/…`
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
  lives in `.devflow/config.json` (created from the example). This repo **tracks**
  its live `config.json` — force-added past the `/.devflow/*` ignore rule with
  `git add -f` so the cloud tier reads it from the committed tree — so keep secrets
  and owner-specific IDs out of it. The `.devflow/learnings/` corpus
  (`retrospectives.jsonl`, `experiment-records.jsonl`, `overrides.json`) is likewise
  tracked and published — re-included by the `!/.devflow/learnings/` negation in
  `.gitignore` — so keep host-local and owner-identifying data —
  operator home-directory paths, account names — out of it too;
  `lib/materialize-retrospectives.sh` rewrites operator home prefixes to `~` on the
  merge write path as a backstop, but the rule is the primary guard.
- New `.py`/`.sh` files carry an SPDX header:
  ```
  # SPDX-FileCopyrightText: 2026 Daniel Radman
  # SPDX-License-Identifier: MIT
  ```
- **Every `skills/*/SKILL.md` carries the standardized consumer prompt-extension
  step.** As a preflight, each skill invokes
  `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh <skill-name>` and honors
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
- **A skill loads the extensions its behavior draws on — usually one, sometimes more
  (issue #620).** The step above is a floor, not a cap: a skill that applies *another*
  skill's principles without invoking that skill loads that skill's extension too, so the
  policy follows the behavior rather than the invocation. `/devflow:review-and-fix` is the
  instance — its preamble loads `review-and-fix` and then `receiving-code-review`, because
  the fix loop applies those principles without ever invoking that skill. When you add or
  change a skill, ask which other skills' principles it applies un-invoked. The rule and
  its coverage are stated in
  [`docs/DEVFLOW_SYSTEM_OVERVIEW.md`](docs/DEVFLOW_SYSTEM_OVERVIEW.md) under *Extending
  skills with prompt extensions*.
- Prompt cutovers, trims, relocations, and mandatory-surface growth follow the artifact
  procedure in [`.devflow/prompt-extensions/implement.md`](.devflow/prompt-extensions/implement.md)
  under **Prose cutover**.

## Cloud-tier workflows

The `.github/workflows/*.yml` files run inside GitHub Actions, where they reference
plugin scripts at `.devflow/vendor/devflow/scripts/…`. That path assumes the cloud
tier is used with the plugin **vendored** into the consuming repo at that path (see
`docs/cloud-setup.md`). This is intentional and distinct from the local skills, which
resolve the portable `${CLAUDE_SKILL_DIR:-…}` anchor at runtime.

## Submitting changes

1. Branch, make focused changes, run `bash lib/test/run.sh`.
2. Open a PR with a clear description. If your change reaches consumers (the engine surface —
   `skills/`, `agents/`, `lib/`, `scripts/`, the workflows, the config schema), add a
   **changeset** instead of editing `CHANGELOG.md` or `.claude-plugin/plugin.json`: create a
   uniquely-named `.changeset/<slug>.md` with a `bump: patch|minor|major` frontmatter key and
   your Keep-a-Changelog prose (PR-cited). See [`.changeset/README.md`](.changeset/README.md).
   Internal-only changes (tests, CI, dev-only docs) need no changeset.
3. Be kind in review (see `CODE_OF_CONDUCT.md`).

### Versioning (changesets)

DevFlow versions itself with changesets so concurrent PRs never collide on the `version` line
or the top of `CHANGELOG.md`. Each PR adds a `.changeset/*.md`; when it merges to `main`, the
`version-consolidate` GitHub Action (`.github/workflows/version-consolidate.yml`),
running `scripts/consolidate-changesets.py`, bumps
`.claude-plugin/plugin.json` by the **highest**
pending bump type, prepends one dated, PR-cited CHANGELOG entry assembled from all the pending
prose, deletes the consumed changesets, and commits to `main` with a `chore: bump version`
subject. A malformed changeset fails the Action loudly; with no pending changesets it is a
clean no-op. Cadence stays per-merge — every merged *engine-surface* change (one carrying a
changeset) still ships as a version increment; an internal-only merge with no changeset is a
deliberate no-op (no bump).
