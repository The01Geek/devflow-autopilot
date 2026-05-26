# DevFlow

[![CI](https://github.com/The01Geek/devflow-autopilot/actions/workflows/ci.yml/badge.svg)](https://github.com/The01Geek/devflow-autopilot/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An end-to-end development-workflow plugin for [Claude Code](https://code.claude.com):
turn a GitHub issue into a reviewed, documented, merged PR — and learn from every run.

DevFlow bundles four things, plus a self-improving loop:

1. **`/devflow:implement`** — a 4-phase orchestrator (setup → implement → review → document) that drives a GitHub issue all the way to a ready PR.
2. **`/devflow:review` and `/devflow:review-and-fix`** — a verification-checklist-driven code-review engine (`/devflow:review` reports a verdict; `/devflow:review-and-fix` fixes findings and loops until it approves).
3. **The `/docs` suite** — keep internal docs, external docs, and release notes aligned with the code.
4. **`/create-issue`** — turn a rough user story or bug report into a well-structured GitHub issue.

…plus a **self-improving loop** (`/devflow:retrospective-weekly`) that reads the evidence trail of merged bot-authored PRs, finds recurring failure patterns, and opens human-reviewed PRs proposing the smallest change that would prevent the next occurrence. See [The retrospective loop](#the-retrospective-loop).

> **Two tiers.** The **local tier** — the skills you run inside Claude Code — works with **zero configuration and no infrastructure**. The optional **cloud tier** (GitHub Actions) makes DevFlow run *autonomously* on issue/PR events; it needs a Claude Code OAuth token and a little setup (see [`docs/cloud-setup.md`](docs/cloud-setup.md)).

## Prerequisites

The local skills need these on your PATH:

- **`git`**
- **[`gh`](https://cli.github.com)** (GitHub CLI), authenticated (`gh auth login`)
- **`jq`**
- **Python 3.11+** with **PyYAML** — `python3 -m pip install -r requirements.txt`

Run `bash lib/preflight.sh` to verify. (Shell helpers avoid GNU-only flags, so macOS/BSD work without GNU coreutils.)

## Install

DevFlow is published as a Claude Code plugin from this repository, which is also its own marketplace.

**Quick install** — one line in your terminal:

```bash
claude plugin marketplace add anthropics/claude-plugins-official && claude plugin marketplace add The01Geek/devflow-autopilot && claude plugin install devflow@devflow-marketplace
```

**Or from inside Claude Code:**

```text
/plugin marketplace add anthropics/claude-plugins-official
/plugin marketplace add The01Geek/devflow-autopilot
/plugin install devflow@devflow-marketplace
```

Then run `/reload-plugins` (or restart) to activate.

That's it for the local tier. DevFlow declares three companion plugins as **dependencies** — `feature-dev`, `pr-review-toolkit`, and `superpowers` (all from the official `claude-plugins-official` marketplace). The `/plugin install` step **auto-installs them itself** (no `curl`/`install.sh` needed) **as long as `claude-plugins-official` has been added** — which is why the commands above add it first. The official marketplace is *discoverable* by default, but cross-marketplace dependencies only resolve once it's actually **added**; on a fresh machine where it hasn't been, DevFlow lands in the `/plugin` **Errors** tab with `dependency-unsatisfied` until you add the marketplace (then `/reload-plugins`) or install the three plugins manually. The deps install at the same scope as DevFlow and appear in `/plugin` as their own `@claude-plugins-official` entries, not nested under DevFlow. `/simplify` is a built-in Claude Code skill and needs no installation.

> **Not** auto-installed: the **PyYAML** Python dependency (used by DevFlow's shell helpers). Plugin install only resolves companion *plugins* — it never runs `pip`. Install PyYAML yourself per [Prerequisites](#prerequisites) (`python3 -m pip install -r requirements.txt`); `install.sh` also handles it for the cloud tier.

For autonomous GitHub Actions automation (the "cloud tier"), run this from your repo root — the same command installs and later updates it:

```bash
curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/main/install.sh | bash
```

See **[`docs/cloud-setup.md`](docs/cloud-setup.md)** for secrets, triggers, and the full guide.

> **Thin by default.** `install.sh` does **not** commit the plugin tree to your repo — it installs the workflows, composite actions, a local `marketplace.json`, and a `.devflow/config.json` scaffold, and pins a `devflow_version` (the commit it installed from). At runtime the workflows materialize the plugin into `.devflow/vendor/devflow/` via the `vendor-plugin` composite action, so there's no bulky vendored diff to carry. Pass `DEVFLOW_VENDOR=1` to commit the tree instead (self-hosting; `devflow_version` is then ignored).
>
> **Both tiers on one repo?** No conflict — the local marketplace copy is cached centrally; the cloud tier materializes its own copy under `.devflow/vendor/devflow/` at runtime (or commits one with `DEVFLOW_VENDOR=1`). Just don't run `/plugin marketplace add ./` there (it would activate two marketplaces named `devflow-marketplace`).

## Updating

- **Local tier** — enable auto-update once and Claude Code pulls new versions at startup; set `autoUpdate` on the marketplace in `~/.claude/settings.json`:
  ```jsonc
  "extraKnownMarketplaces": {
    "devflow-marketplace": {
      "source": { "source": "github", "repo": "The01Geek/devflow-autopilot" },
      "autoUpdate": true
    }
  }
  ```
  Or update on demand: `/plugin marketplace update devflow-marketplace`.
- **Cloud tier** — bump `devflow_version` in `.devflow/config.json` to a newer tag, branch, or commit SHA (the workflows fetch that ref at runtime), or just re-run the same `install.sh` — now a small diff, since it re-stamps `devflow_version` and refreshes the workflows/actions without committing the plugin tree, and keeps your config. (The plugin must be at the literal workspace path when CI runs because a marketplace install isn't reachable from the Actions sandbox — the `vendor-plugin` action satisfies this at runtime; see [`docs/cloud-setup.md`](docs/cloud-setup.md#why-the-plugin-lives-at-a-workspace-path-not-added-as-a-github-marketplace-in-ci).)

## The workflow, end to end

Here's the whole loop, from a rough idea to a reviewed pull request. This is the
intended way to drive DevFlow.

```
   you: a rough idea
        │
        ▼
  ┌───────────────────┐   /devflow:create-issue
  │ 1. Create issue   │   turns the idea into a structured GitHub issue
  └───────────────────┘   (asks clarifying questions, you confirm before it files)
        │
        ▼
  ┌───────────────────┐   comment  /devflow:implement <#>  on the issue
  │ 2. Trigger        │   (this is the trigger — a human comment starts it)
  └───────────────────┘
        │
        ▼
  ┌───────────────────┐   devflow-implement.yml runs /devflow:implement autonomously:
  │ 3. Implement      │   branch → plan → code → tests → draft PR → /simplify →
  └───────────────────┘   /devflow:review-and-fix → docs → marks the PR ready
        │
        ▼
  ┌───────────────────┐   devflow-review.yml posts a /devflow:review verdict as a
  │ 4. Review gate    │   PR check; you review and merge
  └───────────────────┘
```

### Step by step

1. **Create the issue.** In Claude Code:
   ```
   /devflow:create-issue Add CSV export to the reports page
   ```
   It interviews you until the issue is unambiguous, shows you the rendered draft,
   and files it **only after you confirm**. Say the issue lands as **#42**.

2. **Start implementation by commenting the command.** Comment
   `/devflow:implement 42` on issue #42 — in the GitHub UI or from the CLI:
   ```bash
   gh issue comment 42 --body '/devflow:implement 42'
   ```
   That's the trigger (no `@claude` prefix — that's ceded to Anthropic's Claude
   GitHub App). Because *you* posted the comment (a real user event), GitHub fires
   `devflow-implement.yml` natively — no bot comment, PAT, or GitHub App needed.
   Triggering takes write/triage access (you must be an allowed bot or an
   `allowed_users` collaborator), so that permission is what gates who can start a
   run — see [the note in cloud-setup](docs/cloud-setup.md#triggering-devflowimplement).

3. **DevFlow implements it.** The workflow runs the full `/devflow:implement`
   lifecycle on its own: creates a branch, plans against your codebase, writes the
   code and tests, opens a **draft PR**, self-reviews with `/simplify`, runs
   `/devflow:review-and-fix`, files follow-up issues for any deferred findings,
   updates the docs, and flips the PR to **ready**.

4. **Review and merge.** `devflow-review.yml` runs `/devflow:review` as a gate and
   posts its verdict on the PR. You do the final human review and merge.

> **Prefer the editor?** Run `/devflow:implement 42` directly in Claude Code
> instead of commenting on the issue — both reach the same lifecycle.

The cloud tier (steps 2–4 running automatically on GitHub) needs only
`CLAUDE_CODE_OAUTH_TOKEN` set as a secret — see [`docs/cloud-setup.md`](docs/cloud-setup.md).
Everything else runs locally inside Claude Code with no infrastructure at all.

## Skills and agents

| Skill | What it does | Invoked |
|---|---|---|
| `/devflow:implement <issue#>` | Full lifecycle: fetch issue → branch + workpad → discover/plan → implement → test → draft PR → `/simplify` → `/devflow:review-and-fix` → acceptance gate → file follow-up issues for deferred findings → docs → ready PR | interactively, or by commenting `/devflow:implement <n>` on an issue (cloud tier) |
| `/devflow:review [PR#]` | Comprehensive review: verification checklist (generated + verified against source), then `pr-review-toolkit` + `superpowers` reviewers; in PR mode matches the Scope-Acknowledged Findings block and demotes acknowledged findings; returns APPROVE/REJECT | interactively, or by commenting a bare `/devflow:review` on the PR |
| `/devflow:review-and-fix [PR#]` | `/devflow:review` + an automatic fix loop (max 4 iterations); writes a deferrals manifest at Loop Exit | interactively; called by `/devflow:implement` Phase 3 |
| `/devflow:pr-description [issue#]` | Generate/update the PR description from the branch diff; renders the Scope-Acknowledged Findings block when present | interactively; called by `/devflow:implement` Phase 4 |
| `/devflow:docs` | Orchestrates the three doc steps in one session | interactively; called by `/devflow:implement` Phase 4 |
| `/devflow:docs-sync-internal` | Update internal docs to match code changes on the branch | interactively; called by `/docs` |
| `/devflow:docs-sync-external` | Align external customer docs with the updated internal docs | interactively; called by `/docs` |
| `/devflow:docs-release-notes` | Generate a release-notes entry for customer-visible changes | interactively; called by `/docs` |
| `/devflow:docs-verify <topic>` | Verify/refresh internal docs for one topic against the codebase | interactively |
| `/devflow:docs-bootstrap-internal` | Stand up an internal-docs structure from scratch | interactively |
| `/devflow:docs-bootstrap-external` | Generate the initial external docs from internal docs | interactively |
| `/devflow:create-issue` | Rough idea → well-structured GitHub issue | interactively |
| `/devflow:init` | One-time setup: scaffold `.devflow/config.json` from the template (only if absent) + refresh `config.schema.json` | interactively |
| `/devflow:retrospective-weekly` | The weekly self-improvement loop orchestrator | interactively / headless |
| `/devflow:retrospective` | Stage A brief — per-PR retrospective analysis | subagent only (dispatched by `/devflow:retrospective-weekly`) |
| `/devflow:retrospective-audit` | Stage B brief — per-pattern intervention drafting | subagent only (dispatched by `/devflow:retrospective-weekly`) |

**Agents** (`agents/`): `checklist-generator`, `checklist-deduper`, and `checklist-verifier` (used by `/devflow:review` and `/devflow:review-and-fix` to build, dedupe, and verify the verification checklist).

> DevFlow's commands are written in their `devflow:`-namespaced form (`/devflow:implement`, `/devflow:review`, …) throughout these docs — that's the canonical invocation and the form the cloud workflows use. **Namespacing matters most for the names that collide with built-ins:** `/review`, `/init`, and `/security-review` are *built-in* Claude Code commands, so a bare `/review` reaches Claude Code's PR reviewer (not DevFlow's review engine) and a bare `/init` runs Claude Code's CLAUDE.md generator (not DevFlow's config scaffolder). Always use `/devflow:review` and `/devflow:init` to reach DevFlow — especially from GitHub Actions comments, where the namespaced form is required. DevFlow's cloud workflows live in `devflow.yml`, `devflow-implement.yml`, and `devflow-review.yml` and trigger on **bare** `/devflow:*` comments (no `@claude`); DevFlow never creates or overwrites `claude.yml`, so it coexists with Anthropic's Claude GitHub App, which owns plain `@claude` mentions, Q&A, and `/security-review`.

## Companion plugins (auto-installed dependencies)

| Plugin | Used by | Source |
|---|---|---|
| `feature-dev` | `/devflow:implement` dispatches `feature-dev:code-explorer` (discovery) and `feature-dev:code-architect` (planning) | `claude-plugins-official` |
| `pr-review-toolkit` | `/devflow:review` runs `code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, `pr-test-analyzer`, and (gated) `type-design-analyzer` | `claude-plugins-official` |
| `superpowers` | `/devflow:review`'s final-pass reviewer (`/superpowers:requesting-code-review`); brainstorming/TDD discipline | `claude-plugins-official` |
| `/simplify` | `/devflow:implement` Phase 3.2 self-review | **built-in** Claude Code skill |

The three `claude-plugins-official` plugins above are **auto-installed** by `/plugin install devflow@devflow-marketplace` (they're declared as dependencies in `plugin.json`) — **provided the `claude-plugins-official` marketplace has been added first** (see [Install](#install)); otherwise DevFlow shows in the `/plugin` Errors tab and you install them manually. `/simplify` is built in. This auto-install covers companion *plugins* only — the **PyYAML** Python dependency is separate and is **not** installed by `/plugin`. Skills degrade gracefully if an optional companion is somehow missing (the review engine falls back to its other reviewers).

## Project configuration

The local tier needs **no config** — every value has a built-in default. To customize, scaffold the config files:

```
/devflow:init
```

This creates `.devflow/config.json` from DevFlow's shipped template (only if you don't already have one — it never clobbers a config you've filled in) and refreshes `.devflow/config.schema.json`. It pulls the templates from the installed plugin, so it works even though they aren't in your repo — a plain `cp .devflow/config.example.json …` only works from the DevFlow source repo, not a marketplace install. The cloud-tier `install.sh` runs the *same* scaffolder, so the two are interchangeable and safe to run in any order: whichever runs first creates `config.json`; the other leaves it untouched and just refreshes the schema.

(`/devflow:init` / `install.sh` write a scoped `.devflow/.gitignore` that ignores only the ephemeral `.devflow/tmp/` scratch — `config.json` itself stays committed, since it now holds working defaults rather than environment-specific IDs, and the cloud tier reads it from the committed tree. Your editor reads `config.schema.json` for autocomplete + field descriptions.) Keys the skills read:

- `docs.internal`, `docs.external` — documentation paths (read by the `/docs` family and `/devflow:implement`).
- `docs.release_notes_file`, `docs.labels` — release-notes path + the comma-separated list of labels `/devflow:implement` applies after its docs pass (e.g. `"Documented, Shipped"`; each entry trimmed, empty entries dropped).
- `devflow.workpad_marker` — marker line `/devflow:implement` uses to find/update its single per-issue workpad comment (default `<!-- devflow:workpad -->`).
- `devflow.allowed_bots` — bot login allowlist; doubles as the **trusted-filer allowlist** for the Scope-Acknowledged Findings contract.
- `base_branch` — review/merge base (default: repo default branch, else `main`).
- `devflow_retrospective.*` — settings for `/devflow:retrospective-weekly` (see [Configuration](#configuration)).
- `setup.*` — *cloud tier only*: how the GitHub Actions runner provisions its toolchain (`python_version`, `node_version`, `install`) before Claude runs. See [`docs/cloud-setup.md`](docs/cloud-setup.md#runtime-provisioning-setup).
- `devflow_version` — *cloud tier only*: the git ref (tag, branch, or commit SHA) the workflows fetch the plugin from at runtime on a thin install. `install.sh` pins it to the commit it installed from; bump it to update. Ignored when the plugin is committed (`DEVFLOW_VENDOR=1`) or in the source repo. Empty by default so an un-pinned thin install fails loud instead of tracking mutable `main`.

---

# Scope-Acknowledged Findings

A structured handoff between `/devflow:review-and-fix`, `/devflow:implement`, `/pr-description`, and `/devflow:review` so a Critical finding deliberately deferred during the fix loop is not re-raised as a fresh REJECT by the next review run.

**The handoff, in order.**

1. **`/devflow:review-and-fix` Loop Exit** runs a **widens-surface guard** on every Yes-downgrade skip — if the PR diff overlaps the deferred finding's file within ±10 lines, the skip is disqualified. Survivors are emitted as `.devflow/tmp/review/<slug>/deferrals.json`.
2. **`/devflow:implement` Phase 4.0.5** reads that manifest, runs `scripts/file-deferrals.py` to file **one follow-up issue per source file** (body contains the verbatim findings plus a `PR #<N>` cross-link), and rewrites the manifest with deterministic `id: dfr-<6-hex>` + `follow_up` fields.
3. **`/pr-description`** renders a Scope-Acknowledged Findings block between `<!-- DEVFLOW_DEFERRED_FINDINGS_START -->` / `END` markers in the PR body.
4. **`/devflow:review` Phase 4.0** (PR mode) runs `scripts/match-deferrals.py`, which validates each deferral against three guards and demotes matched findings to **Informational** before computing the verdict.

**The three guards** (any failure rejects the deferral): **trusted filer** (PR author in `devflow.allowed_bots`); **mutual cross-link** (the follow-up issue exists, is open, and references `PR #<current_pr_number>`); **widens surface** (re-checked at review time). The contract is repo-agnostic: trusted-filer from `devflow.allowed_bots`, base branch from `base_branch`.

---

# The retrospective loop

A two-stage evaluator/optimizer self-improvement loop for the `/devflow:implement` automation. Every bot-authored PR leaves evidence — review comments, post-bot commits, CI signals, workpad state. Once a week, `/devflow:retrospective-weekly` reads the accumulated trail, finds patterns that recur, and opens a human-reviewed PR proposing the smallest change that would have prevented the next occurrence (a CLAUDE.md tweak, a skill rewrite, a missing doc, a new lint rule, a tightened issue template). Humans approve or reject.

## How to run it

```text
/devflow:retrospective-weekly
```

Run it in an interactive Claude Code session from the repo root, ideally weekly. The skill confirms you're on the default branch with a clean tree, then runs the full pipeline and prints a status report with the state PR + any intervention PRs to review.

**Cron / headless variant:**

```bash
claude -p "/devflow:retrospective-weekly" --permission-mode acceptEdits
```

If Stage B edits engine paths unattended (skill-file interventions), it would need `--dangerously-skip-permissions` — but the **recommended mode is the interactive run**, where you approve each change. (This flag disables all permission prompts; use it only in a trusted, sandboxed scheduler.)

> **Who runs this?** The retrospective loop is primarily DevFlow improving DevFlow, run on this repo. Adopters can run it on their own repo to retrospect their bot's PRs; if your bot uses a branch prefix other than `claude/`, set `devflow_retrospective.implementation_branch_prefix`.

## The pipeline (LLM/heuristic split)

Deterministic scripts handle all scanning, fetching, signal computation, gating, pattern math, and git/PR/issue mechanics. The LLM is invoked **only** at two genuine-judgment points: **Stage A** (per-PR retrospective, only for PRs that fail the mechanical clean gate) and **Stage B** (per-pattern intervention drafting). Everything else costs zero LLM tokens.

```text
scan.sh
  → fetch-pr-context.sh  (per PR)
    → cheap-gate.jq
      [clean]  → clean-entry.jq / audit-entry.jq   (deterministic, no LLM)
      [not clean] → Stage A: retrospective subagents (≤3–4 concurrent)
  → materialize-retrospectives.sh
  → actionable-patterns.sh  (uses compute-patterns.jq)
    → Stage B: retrospective-audit subagents
      [excluded path] → meta-issue.sh + overrides.json dismissal
      [safe path]     → git commit + push + gh pr create
  → open-state-pr.sh
  → post-status.sh
```

## Data

- **`.devflow/learnings/retrospectives.jsonl`** — append-only ground truth; one JSON object per processed PR (`kind: implementation | audit`). Tracked in git.
- **`.devflow/learnings/overrides.json`** — human-editable map of dismissed patterns + reasons. Tracked in git.
- **`.devflow/tmp/`** — all ephemeral scratch for each run: review caches (`tmp/review/<slug>/` — cached diff, per-iteration workpads, deferrals manifest), weekly-loop temp files, and issue drafts. Gitignored via a scoped `.devflow/.gitignore` (which ignores only `tmp/`, so `config.json` and `learnings/` stay committed).

Pattern occurrences, fix history, and status (`open`/`regressed`/`fixed`/`dismissed`) are computed on demand by `lib/compute-patterns.jq`. The loop is **idempotent** — re-running processes only PRs not already in `retrospectives.jsonl` on the default branch.

### Inspect the current pattern view

From the plugin's directory (or a checkout of this repo):

```bash
jq -s -f lib/compute-patterns.jq \
   --slurpfile overrides .devflow/learnings/overrides.json \
   .devflow/learnings/retrospectives.jsonl
```

## Exclusion list (design-review paths)

When an actionable pattern's best fix touches one of DevFlow's **own engine files**, Stage B returns `excluded: true` instead of editing, and the orchestrator files a `[devflow-retrospective] meta: <tag>` issue + records a dismissal override. `lib/check-excluded-path.sh` enforces this list:

```text
skills/**          agents/**          lib/**          scripts/**
.claude-plugin/**  .devflow/learnings/**
.github/workflows/claude*.yml  .github/workflows/devflow-*.yml
.github/actions/**  .devflow/config.json  .devflow/config.example.json  .devflow/config.schema.json
```

## Configuration

Under `devflow_retrospective` in `.devflow/config.json` (all optional — defaults shown):

```json
"devflow_retrospective": {
  "enabled": true,
  "watched_authors": [],
  "implementation_branch_prefix": "claude/",
  "min_occurrences": 2,
  "cooldown_days": 3,
  "max_prs_per_run": 500,
  "retrospective_model": "",
  "audit_model": ""
}
```

- `watched_authors` — defaults to `devflow.allowed_bots` when `[]`.
- `implementation_branch_prefix` — your bot's PR branch prefix.
- `min_occurrences` — times a pattern must recur to be actionable.
- `cooldown_days` — skip a pattern if an open audit PR is younger than this.
- `max_prs_per_run` — cap on PRs processed per run.
- `retrospective_model` / `audit_model` — optional `--model` overrides for Stage A / Stage B.

## Repository layout

```text
.claude-plugin/
├── plugin.json          # plugin manifest (declares dependencies)
└── marketplace.json     # this repo is its own marketplace
skills/                  # the /devflow:implement, /devflow:review, /docs, … skills (one SKILL.md each)
agents/                  # checklist-generator/-deduper/-verifier
scripts/                 # branch-for-issue.py, config-get.sh, file-deferrals.py,
                         #   match-deferrals.py, parse-acs.py, workpad.py,
                         #   dismiss-stale-rejections.sh
lib/                     # retrospective-loop helpers (*.sh, *.jq), preflight.sh,
                         #   intervention-surfaces.md, test/
.github/                 # optional cloud tier: workflows + composite actions
                         #   (incl. vendor-plugin, which materializes the plugin at runtime)
.devflow/                # config.example.json + config.schema.json (+ learnings/, logs/)
docs/                    # cloud-setup.md, implement-skill.md, workflow-triggers.md, efficiency-trace.md
install.sh               # one-command cloud-tier install/update (thin by default; DEVFLOW_VENDOR=1 to commit the plugin)
```

Skills reference their bundled helpers via `${CLAUDE_SKILL_DIR}` so they resolve from any install location.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run the test suite with `bash lib/test/run.sh` (CI runs it on every PR). Security reports: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Daniel Radman.
