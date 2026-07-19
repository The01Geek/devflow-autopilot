# DevFlow — agentic coding that ships on real codebases

[![DevFlow — Ship the PR, not the cleanup. A Claude Code plugin that turns one request into one merge-ready pull request across four phases: Setup (/devflow:create-issue), Implement (/devflow:implement), Review & fix (/devflow:review-and-fix), and Document (/devflow:docs).](docs/ship-pr.png)](https://the01geek.github.io/devflow-autopilot/)

[![CI](https://github.com/The01Geek/devflow-autopilot/actions/workflows/ci.yml/badge.svg)](https://github.com/The01Geek/devflow-autopilot/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Built on Claude Code](https://img.shields.io/badge/built%20on-Claude%20Code-d97757.svg)](https://code.claude.com)

**AI coding agents dazzle on a demo repo, then stall on a real ticket in a large production codebase.** DevFlow is the [Claude Code](https://code.claude.com) plugin that closes that gap — it carries one feature request all the way to a **complete, tested, reviewed, documented pull request**, so you do the final review and merge, not the cleanup.

<!--
  DEMO SLOT — highest-impact addition per README research (see docs/demo-gif.private.md).
  Record a ~20-30s terminal GIF of the headline flow and drop it in here:
    /devflow:implement 42  →  branch → plan → code+tests → draft PR → review-and-fix → ready PR
  Keep it < 3 MB, loop-friendly, captioned. Replace this comment with:
    ![DevFlow turning issue #42 into a ready PR](docs/demo.gif)
-->

## Quick start

> [!TIP]
> **Just ask your agent.** Paste this into Claude Code and it handles steps 1 and 2 for you — the install, the setup, and the PATH dependencies `/plugin install` doesn't cover. Then ship your first PR with step 3.
>
> ```text
> Read https://github.com/The01Geek/devflow-autopilot#quick-start and install DevFlow and its dependencies.
> ```

**1. Install** (two commands — run in order; works in any shell):

```bash
claude plugin marketplace add The01Geek/devflow-autopilot
claude plugin install devflow@devflow-marketplace
```

**2. Set up** — launch Claude Code and scaffold your config:

```bash
claude /devflow:init   # launches Claude Code and scaffolds your config
```

**3. Ship a PR** — turn a feature request into a reviewed, documented pull request:

```text
/devflow:create-issue <user_story>
/devflow:implement <issue_number>
```

The local tier runs **with zero configuration** — every value already has a built-in default. `/devflow:init` is recommended: it keeps the plugin auto-updated and writes a `.devflow/config.json` you can tweak. See **[Installing & updating](docs/install.md)** for the full options (the zero-dependency install, PyYAML, the cloud tier) and [Requirements](#requirements) for the handful of tools it expects on your PATH.

## Why DevFlow

- **Ships the whole PR, not a fragment** — grounded in *your* architecture and patterns, with the tests the change actually needs, on production code. [How it's different →](#how-its-different)
- **Review that fixes what it finds — and audits itself** — the review-and-fix loop applies fixes and re-reviews until it approves, then a structurally-independent **shadow pass** re-checks the approval. [Skills and agents →](#skills-and-agents)
- **Docs stay in sync** — internal docs, external docs, and release notes kept aligned with the code in the same run.
- **It learns every week** — a [retrospective loop](#the-self-improving-loop) reads the trail of merged PRs and files human-reviewed issues that prevent the next recurring failure.
- **Zero-config to start** — the local tier runs entirely inside Claude Code with no infrastructure; an optional [cloud tier](docs/cloud-setup.md) runs it autonomously on GitHub.

> ▶ **[See the full loop in the interactive one-pager →](https://the01geek.github.io/devflow-autopilot/)**

<details>
<summary>Contents</summary>

- [How it's different](#how-its-different)
- [Who it's for](#who-its-for)
- [The workflow, end to end](#the-workflow-end-to-end)
- [Requirements](#requirements)
- [Skills and agents](#skills-and-agents)
- [Project configuration](#project-configuration)
- [The self-improving loop](#the-self-improving-loop)
- [Learn more](#learn-more)
- [Repository layout](#repository-layout)
- [Contributing](#contributing)

</details>

## How it's different

The thesis isn't code generation — it's **disciplined, auditable AI software delivery at production scale.** A single LLM pass is variable; DevFlow's architecture is built around *not trusting any single pass*.

- **✓ Works on real codebases, not just pet projects.** Unlike a raw agent that drafts part of the change and stops, DevFlow delivers the full round — grounded in your architecture and patterns, with the tests the change needs — on production code.
- **✓ Review that fixes what it finds.** It doesn't just hand you a list. The **review-and-fix loop** applies the fixes and re-reviews, iterating until it approves — backed by independent verification checklists, a panel of specialized reviewers, mechanical corroboration, and a **shadow pass** (a second, structurally-independent review that re-checks the approval before it stands). The shadow pass **narrows the gap to a standalone review; it never closes it.**
- **✓ It learns.** Every run leaves a trail — a **DevFlow Reflection** logging assumptions and anything unverified, an **effectiveness trace** of which steps earned their keep, living docs, and a **weekly retrospective** that opens the smallest fix preventing the next recurring failure.

DevFlow delivers a **review-ready** PR for your final human review and merge — it is **not auto-merged**.

## Who it's for

A developer or team shipping in a **large, business-grade codebase**, already on Claude Code + GitHub, who wants agentic coding to complete a real ticket — branch, tests, review, docs — not just draft a snippet.

## The workflow, end to end

The intended way to drive DevFlow — from a feature request to a reviewed pull request:

```text
   you: a feature request
       │
/devflow:create-issue   →  explore codebase → implementation options → detailed GitHub issue
       │
/devflow:implement      →  architect → code → build/test → /devflow:review-and-fix loop → /devflow:docs
       │
/devflow:review         →  (optional) independent, comprehensive check → PR ready for developer hand-off
       │
   you: final review & merge
```

1. **Create the issue.** `/devflow:create-issue Add CSV export to the reports page` interviews you until the issue is unambiguous, shows you the draft, and files it **only after you confirm**. Say it lands as **#42**.
2. **Start implementation.** Run `/devflow:implement 42` in Claude Code — or, on the cloud tier, comment `/devflow:implement 42` on the issue (`gh issue comment 42 --body '/devflow:implement 42'`). Because *you* posted the comment, GitHub fires the workflow natively (no `@claude`, bot comment, or PAT needed — see [cloud setup](docs/cloud-setup.md#triggering-devflowimplement)).
3. **DevFlow implements it.** It creates a branch, plans against your codebase, writes the code and tests, opens a **draft PR**, self-reviews with `/simplify`, runs `/devflow:review-and-fix`, files follow-up issues for deferred findings, updates the docs, and flips the PR to **ready**.
4. **Review and merge.** On the cloud tier, `/devflow:review` runs as a gate and posts its verdict on the PR. You do the final human review and merge.

> The cloud tier (steps 2–4 running automatically on GitHub) needs only a `CLAUDE_CODE_OAUTH_TOKEN` secret **by default** (routing a workflow through an optional third-party model provider adds one more, `DEVFLOW_PROVIDER_API_KEY`) — see [`docs/cloud-setup.md`](docs/cloud-setup.md). Everything else runs locally inside Claude Code with no infrastructure.

## Requirements

**Local tier** — these must be on your PATH (`bash lib/preflight.sh` checks all of them):

- **`git`** and **[`gh`](https://cli.github.com)** (GitHub CLI, authenticated via `gh auth login`) — you most likely already have these.
- **`jq`** — JSON wrangling inside the skills.
- **Python 3.11+ with PyYAML** — `python3 -m pip install -r requirements.txt`. **The step people miss:** `/plugin install` never runs `pip`, so install PyYAML yourself.

All four are used by the core skills; none is optional. Shell helpers avoid GNU-only flags, so macOS/BSD work without GNU coreutils.

On **Windows** any POSIX **bash** works — **WSL bash**, **Git Bash**, or **MSYS2 bash** (DevFlow mandates none); point DevFlow at the one you want with **`DEVFLOW_BASH`**, and `bash lib/preflight.sh` prints a `devflow-bash:` breadcrumb confirming which bash is in use (a host with *no* POSIX bash at all is out of scope). A non-executable `gh` or `jq` shim can also shadow the real binary on `PATH`; DevFlow resolves the first `gh`/`gh.exe` (and `jq`/`jq.exe`) that actually runs (execution-verified via the shared `lib/resolve-bin.sh` resolver), and you can force a specific binary by setting **`DEVFLOW_GH`** / **`DEVFLOW_JQ`** to the working one. Windows-form paths are normalized to the running shell's POSIX form by `lib/normalize-path.sh`. See [Windows: choosing the bash DevFlow runs under](docs/install.md#windows-choosing-the-bash-devflow-runs-under-devflow_bash), [Windows: resolving `gh`](docs/install.md#windows-resolving-gh), and [Windows: resolving `jq`](docs/install.md#windows-resolving-jq).

**Cloud tier** — nothing to install on your machine; the GitHub Actions runner provisions its own toolchain. By default every job runs on `ubuntu-latest`, but the runner is configurable via the `DEVFLOW_RUNNER` repository/organization variable (a bare label or a JSON label array), which dispatch-enables **self-hosted / Windows runners** — read the prerequisites and the smoke-test boundary in [`docs/cloud-setup.md`](docs/cloud-setup.md) before treating a non-Linux runner as production-ready.

## Skills and agents

| Skill | What it does |
|---|---|
| `/devflow:implement <issue#>` | Full 4-phase lifecycle: issue → branch → plan → implement → test → draft PR → `/simplify` → `/devflow:review-and-fix` → file follow-up issues → docs → ready PR |
| `/devflow:review [PR#]` | Comprehensive review — verification checklist + the first-party `devflow:` review agents & the first-party `devflow:requesting-code-review` final-pass reviewer; returns APPROVE/REJECT |
| `/devflow:review-and-fix [PR#]` | `/devflow:review` plus an automatic fix loop (default 5 iterations) that writes a deferrals manifest at exit |
| `/devflow:pr-description [issue#]` | Generate/update the PR description from the branch diff |
| `/devflow:docs` | Orchestrate the three doc steps in one session |
| `/devflow:docs-sync-internal` · `-sync-external` · `-release-notes` | Update internal docs, align external docs, generate release notes |
| `/devflow:docs-verify <topic>` · `-bootstrap-internal` · `-bootstrap-external` | Verify one topic; stand up internal/external docs from scratch |
| `/devflow:create-issue` | Rough idea → well-structured GitHub issue |
| `/devflow:init` | One-time setup: scaffold `.devflow/config.json` + refresh the schema |
| `/devflow:retrospective-weekly` | The weekly self-improvement loop ([details](#the-self-improving-loop)) |

**Agents** (`agents/`): `checklist-generator`, `checklist-deduper`, and `checklist-verifier` build, dedupe, and verify the review engine's verification checklist.

> **Namespacing matters where names collide with built-ins.** `/review`, `/init`, and `/security-review` are *built-in* Claude Code commands — always use the `/devflow:`-prefixed form to reach DevFlow's engine (a bare `/review` reaches Claude Code's reviewer, not DevFlow's). DevFlow's cloud workflows trigger on **bare** `/devflow:*` comments (no `@claude`), so they coexist with Anthropic's Claude GitHub App, which owns plain `@claude` mentions and `/security-review`.

> **No companion plugins.** DevFlow declares **zero** companion-plugin dependencies — `/plugin install devflow@devflow-marketplace` resolves on its own, with no `claude-plugins-official` prerequisite and none of the old `dependency-unsatisfied` Errors-tab friction. Every external asset its engine once dispatched is now a first-party DevFlow file: the `pr-review-toolkit` review agents and the `feature-dev` `code-explorer`/`code-architect` subagents under `agents/`, and the `superpowers` final-pass reviewer (`requesting-code-review`) and fix-loop `receiving-code-review` skills under `skills/` — all hard-forked with upstream licenses retained verbatim under `LICENSES/`. See [Installing & updating](docs/install.md#no-companion-plugins-to-add). `/simplify` is a built-in Claude Code skill.

## Project configuration

The local tier needs **no config** — every value has a built-in default. To customize, run `/devflow:init` to scaffold `.devflow/config.json` from DevFlow's shipped template (it never clobbers a config you've filled in) and refresh `.devflow/config.schema.json` (your editor reads it for autocomplete + field descriptions).

Common keys the skills read: documentation paths (`docs.internal`, `docs.external`, `docs.release_notes_file`, `docs.changelog_file`, `docs.labels`), the workpad marker (`devflow.workpad_marker`), the bot allowlist (`devflow.allowed_bots`), the review base (`base_branch`), retrospective settings (`devflow_retrospective.*`), and — cloud tier only — runtime provisioning (`setup.*`) and the plugin ref (`devflow_version`). Full reference: **[System overview §17](docs/DEVFLOW_SYSTEM_OVERVIEW.md#17-configuration-reference)**.

## The self-improving loop

Every bot-authored PR leaves evidence — review comments, post-bot commits, CI signals, workpad state. Once a week, **`/devflow:retrospective-weekly`** reads the accumulated trail, finds failure patterns that recur, and files a **human-reviewed** issue proposing the smallest change that would prevent the next occurrence (a CLAUDE.md tweak, a skill rewrite, a missing doc, a new lint rule). You triage it, and it runs through the normal implement → review pipeline like any other change.

```text
/devflow:retrospective-weekly
```

Run it interactively from the repo root, ideally weekly; it confirms a clean default branch, runs the full pipeline, and prints a status report with the issues to triage. Deterministic scripts handle all scanning, gating, and git/issue mechanics — the LLM is invoked **only** at the two genuine-judgment points (per-PR retrospective and per-pattern issue-spec drafting). The loop **proposes, it does not dispose**: it files one well-formed GitHub issue per actionable pattern and lets the normal implement → review pipeline execute it, rather than auto-editing the repo.

Full mechanics — the pipeline, the data files, how patterns become issues: **[System overview §12](docs/DEVFLOW_SYSTEM_OVERVIEW.md#12-deep-dive-the-retrospective-loop)**.

## Learn more

- **[System overview](docs/DEVFLOW_SYSTEM_OVERVIEW.md)** — the complete system reference (architecture, every deep dive, the [Scope-Acknowledged Findings contract §13](docs/DEVFLOW_SYSTEM_OVERVIEW.md#13-the-scope-acknowledged-findings-contract), the [security model §15](docs/DEVFLOW_SYSTEM_OVERVIEW.md#15-security-model)).
- **[Installing & updating](docs/install.md)** — all install paths, dependency resolution, both-tier updates.
- **[Cloud setup](docs/cloud-setup.md)** — secrets, triggers, runtime provisioning for the autonomous tier.
- **[Shadow review](docs/shadow-review.md)** · **[Review-agent overrides](docs/review-agent-overrides.md)** · **[Efficiency traces](docs/efficiency-trace.md)** · **[Workflow triggers](docs/workflow-triggers.md)**
- **[Changelog](CHANGELOG.md)** — release history.

## Repository layout

```text
.claude-plugin/   # plugin.json (declares dependencies) + marketplace.json (this repo is its own marketplace)
skills/           # one SKILL.md per command (/devflow:implement, /devflow:review, /docs, …)
agents/           # checklist-generator / -deduper / -verifier
scripts/          # Python + shell CLIs (workpad.py, config-get.sh, match-deferrals.py, …)
lib/              # retrospective-loop helpers (*.sh, *.jq), preflight.sh, test/
.github/          # optional cloud tier: workflows + composite actions (incl. vendor-plugin)
.devflow/         # config.example.json + config.schema.json (+ learnings/, logs/)
install.sh        # one-command cloud-tier install/update (thin by default; DEVFLOW_VENDOR=1 to commit the plugin)
```

Skills reference bundled helpers via the portable single-statement anchor (`$CLAUDE_SKILL_DIR` on Claude Code, with a runner-reported base-directory fallback on other agentic CLIs) so they resolve from any install location and runner.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run the test suite with `bash lib/test/run.sh` (CI runs it on every PR). Security reports: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Daniel Radman.
