# DevFlow: Complete System Reference

> **Purpose of this document.** This is a single, detail-rich reference describing
> *everything* about the DevFlow system: what it is, who it's for, how every piece
> works, and why the design is the way it is. It is written to be handed to other
> agents (and people) as source material for **marketing decks, technical decks,
> and explainer videos**. It mixes the "elevator pitch" framing marketers need with
> the precise mechanics engineers need, and flags which is which.
>
> **Provenance & accuracy.** Every fact here was extracted from the DevFlow source
> repository (`The01Geek/devflow-autopilot`): the README, the skill definitions
> (`skills/*/SKILL.md`), the agent definitions (`agents/*.md`), the GitHub Actions
> workflows (`.github/workflows/*.yml`), the composite actions, the config schema
> (`.devflow/config.schema.json`), and the docs (`docs/*.md`). Where a number,
> file path, or named mechanism appears, it is quoted as-is so decks/videos don't
> drift from reality. Internal/strategy material (the private roadmap) is
> deliberately **excluded**.
>
> **Current version at time of writing:** DevFlow `2.4.3`. License: MIT © 2026
> Daniel Radman.

---

## Table of contents

1. [The one-sentence pitch](#1-the-one-sentence-pitch)
2. [The problem DevFlow solves](#2-the-problem-devflow-solves)
3. [What DevFlow is, concretely](#3-what-devflow-is-concretely)
4. [The two tiers: local and cloud](#4-the-two-tiers-local-and-cloud)
5. [The end-to-end workflow (the headline demo)](#5-the-end-to-end-workflow-the-headline-demo)
6. [The skill catalog](#6-the-skill-catalog)
7. [Deep dive: `/devflow:implement` (the 4-phase orchestrator)](#7-deep-dive-devflowimplement-the-4-phase-orchestrator)
8. [Deep dive: the review engine (`/devflow:review` + `/devflow:review-and-fix`)](#8-deep-dive-the-review-engine)
9. [Deep dive: shadow review (the audit-your-own-audit mechanism)](#9-deep-dive-shadow-review)
10. [Deep dive: the docs suite](#10-deep-dive-the-docs-suite)
11. [Deep dive: `/devflow:create-issue`](#11-deep-dive-devflowcreate-issue)
12. [Deep dive: the retrospective loop (self-improvement)](#12-deep-dive-the-retrospective-loop)
13. [The Scope-Acknowledged Findings contract](#13-the-scope-acknowledged-findings-contract)
14. [The cloud tier: GitHub Actions architecture](#14-the-cloud-tier-github-actions-architecture)
15. [Security model](#15-security-model)
16. [Observability: efficiency traces & telemetry](#16-observability-efficiency-traces--telemetry)
17. [Configuration reference](#17-configuration-reference)
18. [Installation & updates](#18-installation--updates)
19. [Repository layout](#19-repository-layout)
20. [Glossary](#20-glossary)
21. [Messaging guide: themes, taglines, talking points](#21-messaging-guide)

---

## 1. The one-sentence pitch

**DevFlow makes agentic coding work on real codebases, turning a one-line request into a complete, tested, reviewed, documented pull request that's ready for a developer's final review.**

Out-of-the-box coding agents are dazzling on a demo repo, then you point one at a real ticket in a large, business-grade codebase and it comes back half-done: wrong patterns, missing tests, stale docs. DevFlow is the end-to-end development-workflow plugin for [Claude Code](https://code.claude.com) that closes that gap: it turns a rough idea into a codebase-grounded issue, then orchestrates the full lifecycle, plan, implement, test, review, fix, document, and audits its own review before handing you the PR. Then it closes the loop with a weekly self-improvement pass that reads its own track record and proposes the smallest change that would prevent its next mistake.

---

## 2. The problem DevFlow solves

**The wedge.** AI coding agents can write code, and they look incredible doing it on a fresh, small project. Point one at a real ticket inside a large production codebase and it stalls: it doesn't know the existing patterns, plans against greenfield assumptions, implements half the change, skips the tests, leaves the docs stale, and hands you something that *looks* done but isn't. The hard part of shipping software was never writing code; it's the *workflow around* the code, and that workflow is exactly what breaks down at production scale:

- Turning a vague request into a crisp, buildable spec grounded in *this* codebase.
- Planning against the existing architecture instead of greenfield assumptions.
- Writing the tests, including the test automation the change actually needs.
- Reviewing the change rigorously, not rubber-stamping.
- Fixing what the review finds, then re-reviewing.
- Keeping internal docs, customer docs, and release notes in sync.
- Doing all of this *consistently*, every time, regardless of how big or small the change is.

**What you'd reach for instead, and what it leaves on your plate:**

| Instead of DevFlow | What it leaves you to do |
|---|---|
| Raw coding agents (Claude Code alone, Cursor, Copilot, Devin) | Great on toy projects; on a real codebase *you* still spec, plan, test, review, fix, and document, the agent only drafted part of the code. |
| The stock `@claude` GitHub App | Answers questions and writes code, but enforces no lifecycle, no plan gate, no review-and-fix loop, no docs, no acceptance-criteria check. |
| The manual senior-engineer loop | It works, at the cost of your most expensive people doing spec → plan → implement → test → review → fix → document by hand, inconsistently, on every ticket. |
| Merging the agent's first attempt | The fastest path to a PR that looks done, passes nothing, and resurfaces in production. |

Most "AI writes your code" tools stop at the first step and hand you a diff. DevFlow automates the **entire** loop and treats "committing code as the halfway point, not the finish line."

**The deeper insight (good for a keynote slide).** A single LLM pass is variable: it can miss things, rationalize its own work, or declare victory early, and that variance is exactly what sinks it on a large codebase, where the margin for a half-finished change is zero. DevFlow's architecture is built around *not trusting any single pass*: it uses independent verification checklists, multiple specialized reviewers, a structurally-independent "shadow" re-review to audit its own approval, and a weekly retrospective that audits the whole system. The product thesis is **disciplined, auditable AI software delivery at production scale**: not just code generation.

---

## 3. What DevFlow is, concretely

DevFlow is distributed as a **Claude Code plugin**. The repository is also its own plugin **marketplace**. It bundles:

- **Skills**: the user-facing commands (`/devflow:implement`, `/devflow:review`, the `/devflow:docs` family, `/devflow:create-issue`, `/devflow:retrospective-weekly`, etc.). Each is a `SKILL.md` file containing the procedure the model follows; a larger skill may split its detailed per-phase procedure into on-demand reference files that the `SKILL.md` reads at each step — as `/devflow:implement` does, where a thin orchestrator `SKILL.md` reads one `phases/phase-N-*.md` file at the start of each phase.
- **Agents**: ten specialized first-party subagents — `checklist-generator`, `checklist-deduper`, `checklist-verifier` power the review engine; the five Phase-3 review agents `code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, `pr-test-analyzer`, `type-design-analyzer` do the bulk of `/devflow:review`'s work (vendored from Anthropic's pr-review-toolkit plugin under Apache-2.0, retained at `LICENSES/pr-review-toolkit-LICENSE`); and `code-explorer` (codebase discovery) and `code-architect` (planning) power `/devflow:implement` (vendored from Anthropic's feature-dev plugin under Apache-2.0, retained at `LICENSES/feature-dev-LICENSE`). DevFlow owns all the vendored agents as a hard fork.
- **Scripts** (`scripts/`, `lib/`), deterministic helpers in Bash, `jq`, and Python that do all the mechanical work (fetching context, computing patterns, gating, git/PR mechanics) so the LLM is only invoked for genuine judgment.
- **Cloud workflows** (`.github/`), optional GitHub Actions that make DevFlow run autonomously on issue/PR events.

It declares **zero companion-plugin dependencies** — every external asset the engine once dispatched is now a first-party DevFlow file, internalized as a hard fork across three seams:

- The five Phase-3 review agents (`code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, `pr-test-analyzer`, `type-design-analyzer`) and the discovery/planning subagents `code-explorer` / `code-architect` are first-party agents under `agents/` (vendored from Anthropic's `pr-review-toolkit` and `feature-dev` plugins under Apache-2.0, retained at `LICENSES/pr-review-toolkit-LICENSE` and `LICENSES/feature-dev-LICENSE`), dispatched as `devflow:<name>` — so neither `pr-review-toolkit` nor `feature-dev` is a dependency.
- The final-pass reviewer (`requesting-code-review`) and the fix-loop `receiving-code-review` principles are first-party skills under `skills/` (vendored from the `superpowers` plugin under its MIT license — Jesse Vincent — retained at `LICENSES/superpowers-LICENSE`), dispatched/invoked as `devflow:<name>` — so `superpowers` is no longer a runtime dependency. (The `writing-skills` authoring discipline is **not** vendored — it remains the external `superpowers` skill, a development-time tool DevFlow's own contributors use, not something the engine dispatches.)

DevFlow owns all the vendored agents and skills as a hard fork, and may modify them from this point forward. With the `superpowers` seam internalized there are **no companion-plugin install dependencies left at all** — DevFlow installs and runs on its own.

The "zero companion-plugin dependencies" claim is scoped precisely: it means the **consumer `/plugin install`** resolves with no `claude-plugins-official` prerequisite, and DevFlow's **engine** (everything under `skills/` + `agents/`) dispatches no companion plugin. It is *not* a claim that the cloud workflows install nothing else — `devflow.yml`, `devflow-implement.yml`, and `devflow-runner.yml` still install `code-review@claude-plugins-official` and `claude-md-management@claude-plugins-official` to make the **ambient** `/code-review` and `/revise-claude-md` slash commands available inside the runner. Those are convenience commands the engine never dispatches as part of a review or implementation, so they are not engine dependencies and do not affect the consumer install.

`/simplify` (used for self-review) is a **built-in** Claude Code skill, intentionally *not* a dependency.

---

## 4. The two tiers: local and cloud

This distinction is central to every pitch, lead with it.

### Local tier (zero config, no infrastructure)
The skills you run **inside Claude Code**. Works with **no configuration file at all**: every setting has a built-in default. You type `/devflow:implement 42` (or `/devflow:review`, etc.) in your editor and it runs in your session. Requirements: `git`, `gh` (GitHub CLI, authenticated), `jq`, and Python 3.11+ with PyYAML. A `bash lib/preflight.sh` verifies the environment. Shell helpers avoid GNU-only flags, so macOS/BSD work without GNU coreutils. The toolchain is also self-defending on Windows / non-UTF-8 hosts: a committed `.gitattributes` forces every `*.sh`/`*.py`/`*.jq` to LF on checkout regardless of `core.autocrlf` (so a shebang never becomes `bash\r`), and every first-party `scripts/*.py` forces its own streams and `gh` I/O to UTF-8 (so an em-dash or emoji never trips a cp1252 codec). On a stock Windows Python install (where Python is on PATH only as `python`/`py -3`, with no `python3`), run `bash scripts/provision-python3-shim.sh --apply` once to install a consent-gated `python3` shim that forwards to the first `>=3.11` interpreter — preflight points you there, and it is a no-op on macOS/Linux where a real `python3` already exists. External binaries are resolved with the same execution-verified discipline through a shared resolver family: `lib/resolve-bin.sh` is the single source of truth for the generic selection contract (`devflow_resolve_bin <tool>`), sourced by `lib/preflight.sh` (which only DETECTS) and — via thin per-tool wrappers — by every helper that USES the tool, mirroring their sibling `lib/resolve-python.sh`. The contract: an explicit, non-empty `DEVFLOW_<TOOL>` override (`DEVFLOW_GH`, `DEVFLOW_JQ`) wins outright with no probe; otherwise the first of `<tool>`/`<tool>.exe` whose network- and auth-free `<tool> --version` actually runs is selected (rejecting a present-but-unrunnable Windows/WSL shim); if neither runs, the bare tool is returned with a stderr breadcrumb naming the override remedy (always exit 0). `lib/resolve-gh.sh` delegates to it for `gh` (kept as its own file because every gh-calling helper sources it by name; the `DEVFLOW_GH` contract is unchanged, and the four Python gh-callers — `workpad.py`, `file-deferrals.py`, `match-deferrals.py`, `parse-acs.py` — honor the same override), and `lib/resolve-jq.sh` is the `jq` sibling, sourced by every jq-calling helper to resolve `jq` once into `DEVFLOW_JQ`. `scripts/run-jq.sh` is the agent-tier sibling of that helper for the `jq` an agent composes inside a `SKILL.md` body (currently the retrospective skills): because each skill-body `jq` runs in a fresh per-Bash-call agent shell where `DEVFLOW_JQ` is neither exported nor persisted, the source-once-then-reuse idiom does not translate, so those skills invoke `run-jq.sh` **by path** in place of bare `jq` — it sources the shared `resolve-jq.sh` and execs the resolved binary, selecting a runnable `jq` on a shim-shadowed Windows/WSL host exactly as the helper tier does (a transparent no-op elsewhere; degrades to bare `jq` with a breadcrumb on a partial deployment). `lib/preflight.sh` execution-verifies both `gh` and `jq` with a two-branch diagnosis (not installed vs. present-but-unrunnable, each naming the override remedy); `install.sh` alone carries an inline jq adaptation because it runs standalone before any checkout exists (there a broken `DEVFLOW_JQ` warns and routes to the python3 arm). A companion helper, `lib/normalize-path.sh` (`devflow_normalize_path`), converts a Windows-form path (`C:\...`) to the running shell's POSIX form — `wslpath`, else `cygpath`, else an environment-detected translation (`/mnt/c/...` under WSL, `/c/...` under MSYS/Git Bash), else unchanged with a breadcrumb — and the `create-issue` skill's runner-portable anchor recipe mirrors that chain inline (the anchor is what locates `lib/`, so it cannot source the helper it bootstraps). On macOS/Linux/cloud, where the bare tools run, every resolver returns the bare name on the first probe — no behavior change. The **bash that RUNS** those `.sh` helpers is a level above the resolver family: it is chosen at the invocation boundary (the agent/runner that shells into bash) before any `.sh` executes, so a sourced resolver cannot select it (bootstrap — the resolver would itself need a chosen bash to run). DevFlow supports **any** POSIX bash — WSL bash, Git Bash, or MSYS2 bash, none mandated — and the invocation layer honors a **`DEVFLOW_BASH`** override to point at one. Consistent with its detect-not-select posture, `lib/preflight.sh` is a diagnostic here too: under bash it emits a `devflow-bash:` breadcrumb (interpreter path + `$BASH_VERSION`) and surfaces `DEVFLOW_BASH` when set; run under a non-bash POSIX shell (empty `$BASH_VERSION`) it prints a remedy naming the three supported bashes + the override and exits non-zero before the first bash-only `${BASH_SOURCE[0]}`, failing closed rather than aborting with a cryptic "Bad substitution" (a host with no POSIX bash at all — PowerShell-only — is out of scope). See `CONTRIBUTING.md` for the residual Windows caller-side execution discipline.

### Cloud tier (autonomous, optional)
GitHub Actions workflows make DevFlow run **autonomously on issue/PR events**. You comment `/devflow:implement 42` on an issue and the workflow drives the whole lifecycle without you in the editor. It needs only one secret, `CLAUDE_CODE_OAUTH_TOKEN`, and a little setup (see `docs/cloud-setup.md`). No GitHub App required.

**Both tiers can run on one repo** without conflict. The local marketplace copy is cached centrally; the cloud tier materializes its own copy of the plugin at runtime.

---

## 5. The end-to-end workflow (the headline demo)

This is the canonical story for a demo video or "how it works" slide:

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
  │ 2. Trigger        │   (a human comment starts it)
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

**Narration points:**

1. **Create the issue.** `/devflow:create-issue Add CSV export to the reports page`. DevFlow interviews you until the issue is unambiguous, shows you the rendered draft, and files it **only after you confirm**. Say it lands as **#42**.
2. **Trigger implementation.** Comment `/devflow:implement 42` on the issue. Because *you* (a real user) posted it, GitHub fires the workflow natively, no bot, PAT, or GitHub App needed. (Note: the trigger is the bare `/devflow:*` form, **not** `@claude`, that prefix is ceded to Anthropic's Claude GitHub App.)
3. **DevFlow implements it.** The workflow creates a branch, plans against your codebase, writes code and tests, opens a **draft** PR, self-reviews with `/simplify`, runs `/devflow:review-and-fix`, files follow-up issues for any deferred findings, updates the docs, and flips the PR to **ready**.
4. **Review and merge.** A second workflow runs `/devflow:review` as a gate and posts its verdict as a PR check. A human does the final review and merges.

**Prefer the editor?** Run `/devflow:implement 42` directly in Claude Code, both reach the same lifecycle.

---

## 6. The skill catalog

| Skill | What it does | How it's invoked |
|---|---|---|
| `/devflow:implement <issue#>` | Full lifecycle: fetch issue → branch + workpad → discover/plan → implement → test → draft PR → `/simplify` → `/devflow:review-and-fix` → acceptance gate → file follow-up issues → docs → ready PR | interactively, or by commenting on an issue (cloud) |
| `/devflow:review [PR#]` | Verification-checklist-driven review; runs the first-party `devflow:` review agents + the first-party `devflow:requesting-code-review` final-pass reviewer; returns **APPROVE/REJECT** (no auto-fix) | interactively, or a bare `/devflow:review` comment on the PR |
| `/devflow:review-and-fix [PR#]` | `/devflow:review` + an automatic fix loop (max **4** iterations); writes a deferrals manifest at Loop Exit | interactively; called by `/devflow:implement` Phase 3 |
| `/devflow:pr-description [issue#]` | Generate/update PR description from the branch diff; renders the Scope-Acknowledged Findings block | interactively; called by `/devflow:implement` Phase 4 |
| `/devflow:docs` | Orchestrates the three doc steps in one session | interactively; called by `/devflow:implement` Phase 4 |
| `/devflow:docs-sync-internal` | Update internal docs to match branch code changes | called by `/docs` |
| `/devflow:docs-sync-external` | Align external/customer docs with internal docs | called by `/docs` |
| `/devflow:docs-release-notes` | Generate a release-note entry for customer-visible changes; on a version-bump branch, also reconcile that version's CHANGELOG entry (any PR, not just customer-visible) | called by `/docs` |
| `/devflow:docs-verify <topic>` | Verify/refresh internal docs for one topic (has `--report-only` mode) | interactively; sub-step of `/devflow:create-issue` |
| `/devflow:docs-bootstrap-internal` | Stand up an internal-docs structure from scratch | interactively |
| `/devflow:docs-bootstrap-external` | Generate initial external docs from internal docs | interactively |
| `/devflow:create-issue` | Rough idea → well-structured GitHub issue | interactively |
| `/devflow:init` | One-time setup: scaffold `.devflow/config.json` + refresh schema | interactively |
| `/devflow:retrospective-weekly` | The weekly self-improvement loop orchestrator | interactively / headless |
| `/devflow:retrospective` | Stage A: per-PR retrospective analysis | subagent only |
| `/devflow:retrospective-audit` | Stage B: per-pattern issue-spec drafting | subagent only |

**Agents** (`agents/`): `checklist-generator`, `checklist-deduper`, `checklist-verifier`.

**Naming note (important for accuracy in any demo):** DevFlow's commands use the `devflow:`-namespaced form. This matters most for names that collide with built-ins: `/review`, `/init`, and `/security-review` are *built-in* Claude Code commands, so always use `/devflow:review` and `/devflow:init` to reach DevFlow, especially from GitHub Actions comments, where the namespaced form is required.

### Extending skills with prompt extensions (consumer-owned)

Every skill in the catalog honors one upgrade-safe extension convention. As a standardized first step, each skill runs the bundled reader

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh <skill-name>
```

which prints the contents of `.devflow/prompt-extensions/<skill-name>.md` (resolved relative to the repo root) when that file exists, and the skill treats that text as **additional instructions appended verbatim to the end of its own prompt** for that run. `<skill-name>` is the skill's directory name under `skills/` (`create-issue`, `implement`, `review`, …). When the file is **absent** — or present but empty — the helper prints nothing and the step is a **no-op**: the skill behaves exactly as it does without it. A file that exists but cannot be delivered (unreadable, a broken symlink, or not a regular file) is refused loudly with a non-zero exit and a breadcrumb, and the skill surfaces that rather than silently skipping it — so a misconfigured extension never vanishes without a trace.

**Runner-portable anchor.** `${CLAUDE_SKILL_DIR}` is exported by Claude Code but is *empty* on other agentic CLIs (confirmed on Copilot CLI v1.0.67; expected on Cursor, Codex CLI, Gemini CLI, …), where the bare `${CLAUDE_SKILL_DIR}/../../scripts/…` form collapses to a broken `/../../scripts/…` path. To run first-class on every runner, `/devflow:create-issue` resolves its helper-scripts anchor into a single variable — `SKILL_DIR="${CLAUDE_SKILL_DIR:-<runner-reported skill base directory>}"`, re-established once per bash block since each block runs in a fresh shell — — preferring `$CLAUDE_SKILL_DIR` when set and non-empty (the `:-` expansion treats empty the same as unset) and otherwise falling back to the `Base directory for this skill:` path the runner reports in context — then invokes every helper as `"$SKILL_DIR"/../../scripts/…`. On Claude Code the resolved value is identical to the bare form, so behavior there is unchanged. The recipe carries no skill-specific value, so it is written to be lifted unchanged into the other skills over time (generalization is deferred; `/devflow:create-issue` is the first adopter). This is distinct from the cloud-tier carve-out below, where workflows reference the literal vendored path because the sandbox blocks `$`-expansion.

The extension file lives in the **consumer's** repo, committed under `.devflow/prompt-extensions/` and shared by the team. It is never part of the plugin, so marketplace updates never overwrite it and never conflict with it — the same consumer-owned-vs-plugin separation that keeps your `.devflow/config.json` yours across updates (note the extension files are *tracked/committed* so a team shares them, unlike the gitignored live `config.json`). `/devflow:init` scaffolds the directory with a commented, inert `<skill-name>.md.example` for **every** skill — each carrying a skill-specific hint — so adopters discover that the convention works for all of them, not just one. The examples are backfilled per file (each created only when absent), so an adopter who scaffolded earlier picks up any newly added examples on re-run while their own extension files (an edited `.example`, or a live `<skill-name>.md`) are never overwritten. Re-running the scaffolder also **skips creating a `<skill-name>.md.example` when a live `<skill-name>.md` already exists** for that skill: once an adopter has activated an extension, dropping a redundant `.example` beside it would just be confusing clutter, so the live `.md` (read-only here, never modified) suppresses its own example. A pre-existing `.example` is likewise left untouched. The helper validates the skill-name argument (rejecting any value containing `/` or `..`) before any filesystem access, so the resolved path can never escape `.devflow/prompt-extensions/`.

**Worked example — Azure DevOps test cases in every generated issue.** An adopter who stores test cases in Azure DevOps wants `/devflow:create-issue` to list the applicable test cases in each generated issue body, while upstream DevFlow stays Azure-DevOps-agnostic. They:

1. Register a **project-scoped Azure DevOps MCP server** in their repo's `.mcp.json`.
2. Commit `.devflow/prompt-extensions/create-issue.md` containing, for example:
   > When building the issue body, call the Azure DevOps MCP server to fetch the test cases applicable to this work item and list them under a new "## Applicable Azure DevOps Test Cases" section.

Because the injected text is appended verbatim and MCP tools are model-invoked from prose (not deterministically function-called), the extension must **tell the model to call the tool** rather than assume it runs automatically. No plugin file is edited; the customization is entirely consumer-owned and survives every plugin update.

---

## 7. Deep dive: `/devflow:implement` (the 4-phase orchestrator)

This is DevFlow's flagship. It runs a **mandatory 4-phase lifecycle** for a GitHub issue, every phase runs regardless of issue size. The orchestrator does most work directly in its own continuous session; it uses subagents only for context-isolated work (exploration, architecture, documentation).

> **Tagline:** *"Committing code is the halfway point, not the finish line."* The PR stays a **draft** until Phase 4.3.

### The Workpad: the run's single source of truth
DevFlow maintains **exactly one** marker-tagged comment on the GitHub issue for the whole run (marker: `<!-- devflow:workpad -->`, configurable). It is the durable progress surface, the "job started" acknowledgment, and the resume point. It is driven by `scripts/workpad.py`, a stateless CLI.

- **Status glyphs:** 🚀 (in progress) → 🎉 (`Complete`) → 👎 (`Blocked`). The same vocabulary drives the **emoji reaction** on the triggering comment.
- **Sections (in order):** marker, header, `Status`, `Branch`, `Run`, `PR`, `Last updated`, `## Progress`, `## Plan`, `## Acceptance Criteria`, `## Reproduction` (bug-only), `## Devflow Reflection`.
- **Checkbox ticking is addressable two ways.** `workpad.py update` ticks a `## Progress`/`## Plan`/`## Acceptance Criteria` checkbox either by **unique substring** (`--tick-progress`/`--tick-plan`/`--tick-ac`) or — for Plan and Acceptance Criteria — by **1-based index** within that section (`--tick-plan-n`/`--tick-ac-n`, counting every `[ ]` and `[x]` row in document order; Progress has no index form). The Phase 3.4 acceptance gate ticks ACs by index, so it no longer depends on hand-picked unique prose substrings.
- **Reflection bullets are grouped by kind.** Inside the collapsed `## Devflow Reflection` `<details>` block, `workpad.py update --reflection-kind {blocked|deferred|dropped-failed|note}` renders each bullet with a glyph + bold label under one of two `### ` sub-sections — the three actionable kinds (`⛔ Blocked` / `⏭️ Deferred` / `❗ Dropped/Failed`) under **`### ⚠️ Action required`**, informational `ℹ️ Note` (the default) under **`### ℹ️ Notes`** — so a human sees the items needing follow-up at a glance. Sub-headings are `### ` (level-3, never `## `) so the retrospective parser is not truncated.
- **Rule:** never create a second workpad; always verify a status update actually landed — and for a tick, gate on the **exit code**, not the printed body (see the failure-isolation rule below).
- **Failure isolation (volatile vs. structural).** A `update` call PATCHes once. A **structural** failure (a missing target section, a missing `Status`/`Last updated` line, an unreadable `--*-file`, a failed `gh` PATCH, or a terminal `--status Complete` write with any non-post-merge `## Acceptance Criteria` row still `- [ ]` — the self-record gate that keeps a run from recording itself Complete over an unmet AC; unticked `## Plan` rows and an un-mirrored AC placeholder only warn) aborts the whole call before any change is persisted — all-or-nothing, as before. The one exception is a **volatile per-row tick miss** (a `--tick-*` substring matching zero or multiple rows, or a `--tick-*-n` index out of range or landing on an already-ticked row, *inside a present section*): it is **isolated, not aborted** — every other mutation (`--status`/`--note`/`--reflection` and any tick that did resolve) still applies and PATCHes, and the call then exits non-zero with a stderr report naming each missed tick. A miss is therefore never silently dropped, but because the body still PATCHes (and prints) with the target row left `- [ ]`, callers must treat a non-zero exit from a tick call as "at least one tick did not land" and re-tick only the named row(s).
- In **cloud runs**, a lightweight `gate` job creates a lean workpad *before* the heavy Claude job boots, so the user gets immediate acknowledgment.

### Phase 1: Setup
- **1.1** Fetch the issue (`gh issue view`), note a `bug` label.
- **1.2** Parse Acceptance Criteria via `scripts/parse-acs.py`; tag post-merge items.
- **1.3** Initialize or resume the workpad; if `Status: Blocked`, surface the reflection and pause.
- **1.4** Create or detect the branch (`scripts/branch-for-issue.py`, off the config-driven `base_branch`). Branch creation is skipped when the run is already in a linked git worktree (naming-independent harness signal) or when the current branch matches a recognized feature-branch pattern — the existing branch is reused as-is.
- **1.5** Push the branch.

### Phase 2: Discover, Plan & Implement
- **2.1** Discovery via the first-party `devflow:code-explorer` subagent.
- **2.1.5 Reproduce-First Gate** (bug-labelled only): capture a reproduction signal (failing test / error log) *before* planning; if it can't reproduce → `Blocked`.
- **2.2** Assess complexity. **Simple** (≤5 files, clear, no architecture) → implement directly. **Complex** → the first-party `devflow:code-architect` produces a blueprint (held in context, never committed). Sub-gates: **2.2.4 Reuse & Altitude** (reuse existing helpers by `file:line`), **2.2.5 Scope-Adjustment** (multi-PR issues), **2.2.6 AC-Plan reconciliation**.
- **2.3 Implement** with mandatory post-write **sweeps** (the discipline that prevents half-finished changes — each heading states its own trigger; the five always-on sweeps — convention, boundary-assumption, self-authored-claim, simplification, and error-handling — run on every diff):
  - **2.3.0** Changed-contract sweep (re-run after any merge/rebase of main)
  - **2.3.0a** Peer-checkpoint completeness sweep
  - **2.3.0b** Enum-enumeration reconciliation sweep (added value to an enumerated set → reconcile every enumerating site, incl. doc/comment enumerations and fall-through consumers)
  - **2.3.1** Orphaned-setup sweep
  - **2.3.2** Stranded-dependents sweep
  - **2.3.3** Convention-compliance sweep
  - **2.3.4** Boundary-assumption verification sweep (claims the diff *depends on* about boundaries it doesn't own)
  - **2.3.4a** Self-authored-claim reconciliation sweep (every behavioral claim the diff *authors* in internal/external docs and code comments, reconciled against the shipped code path before commit; the code is the fact)
  - **2.3.5** Simplification & efficiency sweep
  - **2.3.6** Error-handling & silent-failure sweep
- **2.4** Run tests + lint in parallel; fix failures.
- **2.5** Commit (`feat:`) and push.

### Phase 3: Review & Fix
- **3.1** Create the **draft** PR against the configured `base_branch` (`Resolves #{issue}`).
- **3.2** Self-review with the built-in `/simplify` skill; commit fixes (`refactor:`).
- **3.3** Run `/devflow:review-and-fix --push-each-iteration` (the flag propagates each iteration to remote so CI validates). Handles the loop's verdicts, including the special `APPROVE WITH UNRESOLVED SHADOW FINDINGS` (a bounded single re-review). A non-clean exit (AWUSF or `REJECT`) routes through a **severity-aware exit**: only a genuine unresolved Critical (or an unparseable verdict) takes the Blocked path; a non-Critical residual soft-proceeds (surfaced, PR left review-ready).
- **3.4 Acceptance Criteria Gate:** every **non-post-merge** AC checkbox must be ticked (via a passing test, a documented manual check, or a `file:line` reference) before the phase passes. The gate ticks confirmed ACs **by 1-based section index** (`--tick-ac-n`, repeatable in one call) rather than hand-picked prose substrings, and gates on the tick call's **exit code**: a volatile index miss still PATCHes the body while leaving the AC `- [ ]`, so the gate passes only when the targeted row reads `- [x]` **and** the tick exited 0 (an unresolved index re-resolves or routes to Blocked). A `(post-merge)` tag is allowed **only** for a criterion that genuinely needs a runtime environment absent during the run (a live deploy target, a real third-party endpoint). A criterion that is runnable on the orchestrator host — or blocked only by a local tooling/environment gap — and any criterion whose purpose is to confirm a behavioral claim the PR already asserts, is **never** retagged post-merge; it takes the existing **`Blocked`** escalation path instead. This makes the gate enforce "verified before merge" rather than trust the run's narrative. As a special case, an AC whose verification is *running a test/lint/build command* that was **not** observed passing locally is never satisfied by CI deferral alone: after a genuine local-denial fallback, the gate reads the **`lib + python tests`** result for the current `git rev-parse HEAD` and splits three ways — observed **green** for HEAD → tick (recording the gh-resolved SHA via `--note`/`--reflection`); observed **red** for HEAD → the **Blocked** path (a red CI is a real failure, not a deferral); **not-yet-reported** or unreadable → retag `(post-merge)` so the human merger confirms it. A grep of a few SKILL-contract pins is not a substitute for the suite.

### Phase 4: Documentation
- **4.0** File follow-up issues for deferred ACs.
- **4.0.5** Merge all run-scoped deferral manifests into one slug-level aggregate, then file **one follow-up issue per source file** (via `scripts/file-deferrals.py`) for review findings deliberately deferred during the fix loop.
- Both deferral channels (4.0 and 4.0.5) label the follow-up issues they file with the configured **`deferred.labels`** (comma-separated, default `DevFlow,Deferred`) — resolved via `config-get.sh`, normalized like `docs.labels`, ensured via `ensure-label.sh`, and applied best-effort after creation so a label hiccup never blocks filing (an empty/whitespace-only value applies none). Labeling lives in the skill, not `file-deferrals.py` (config stays resolver territory — read through `config-get.sh`, not from Python); it is independent of the hardcoded `DevFlow` provenance label the retrospective scan matches.
- **4.1** Update internal + external docs + release notes (via the `/devflow:docs` subagent); commit (`docs:`); apply configured labels (default `Documented`).
- **4.2** Generate the PR description (`/devflow:pr-description`).
- **4.3** Publish the PR (`gh pr ready`) — unless `devflow_implement.implement_pr_state` is `draft`, which leaves it the Phase 3.1 draft for a human to publish; set status `Complete`; emit the 🎉 reaction (both cases).

---

## 8. Deep dive: the review engine

`/devflow:review` and `/devflow:review-and-fix` share the **same engine**: Phases 0–4.3 are executed verbatim by both. `/devflow:review` reports a verdict; `/devflow:review-and-fix` wraps the engine in a fix loop and skips the GitHub-posting phase.

> **The thesis (good for a technical-deck slide):** don't trust a single review pass. Build an *independent, evidence-based* checklist of every claim the diff makes, verify each claim against the actual source, run a panel of specialized reviewers, and use cross-reviewer corroboration to *calibrate confidence* in each finding, a single-source finding is flagged for extra human scrutiny, never silently dropped.

### Phase 0: Setup & diff classification
Caches the diff to a run-scoped path. **Phase 0.5** classifies the diff with five flags that decide the engine profile:
- `small_diff` (<100 changed lines AND ≤3 files)
- `config_only` (all changed files are config/docs extensions)
- `has_new_types` (added code defines classes/interfaces/types/enums/structs/traits)
- `engine_self_modifying` (touches `skills/**`, `agents/**`, or `lib/**`)
- `detect_all_audit` (the diff adds/changes a "detect-all" scanner/audit/coverage-invariant — code that *enumerates a population* AND *asserts a completeness property* over it)

A `small_diff AND config_only` change skips the checklist phases (intentional). An `engine_self_modifying` change forces the **full** checklist + all four always-on reviewers. `detect_all_audit` is additive (it never suppresses the other flags' profile): it forces a **Phase 3.1.5 completeness-critic pass** that independently re-enumerates the audit's target population by a signal *other than the audit's own pattern* and records any uncovered member as a finding — the engine's guard against a vacuous or self-certified "detect-all" audit.

### Phase 1: Verification checklist generation
The `devflow:checklist-generator` agent (model: **opus**) reads full file contents and enumerates **every verifiable claim** the diff makes, in four categories: **dependency interactions, test-mock alignment, data-format assumptions, API contracts**. Output is a JSON checklist. Key points:
- It **enumerates, does not judge** correctness.
- Files are batched (≤10 per generator; batches of 10 above that).
- The checklist is **capped at 100 items**, prioritized: issue-AC items > dependency_interaction > test_mock_alignment > api_contract > data_format_assumption.
- Each item gets a stable `claim_signature` and a `verification_mode` (`lite` = mechanical grep, or `agent` = needs reasoning).

### Phase 1.5: Dedup (only when >1 batch)
The `devflow:checklist-deduper` agent (model: **sonnet**) merges batches, preserving traceability via a `merged_from` field. It **merges, does not re-judge**: when in doubt it leaves items separate (over-merging hides defects).

### Phase 2: Checklist verification
- **lite** items: the orchestrator runs `grep -n`/`rg` directly (no agent).
- **agent** items: the `devflow:checklist-verifier` agent (model: **sonnet**) verifies each claim against the actual source, returning **PASS / FAIL / INCONCLUSIVE** with `file:line` evidence. Batches of up to **8** in parallel.

### Phase 3: Specialized review agents
All launched in a single message; **always re-run every fix-loop iteration** (the main variance-recovery lever). Four **always-on** reviewers:
- `devflow:code-reviewer`
- `devflow:silent-failure-hunter` (swallowed/over-broadly-caught errors and fail-open fallbacks; also audits **prompt-instruction artifacts** for inert guards — sub-classes `policy-without-mechanism` and `ordered-after-exit`)
- `devflow:comment-analyzer`
- a general-purpose final-pass reviewer invoking the first-party `devflow:requesting-code-review` skill

Two **gated** reviewers:
- `devflow:type-design-analyzer` (only if `has_new_types`)
- `devflow:pr-test-analyzer` (only if the test-relevance predicate matches)

**Completeness-critic pass (Phase 3.1.5, forced when `detect_all_audit` is set):** when Phase 0.5 flags the diff as adding/changing a "detect-all" audit, the engine runs an extra pass that independently re-enumerates the audit's target population *by a signal other than the audit's own pattern* and emits a finding for any uncovered member (folded into the Phase 3 findings set with a `defect_signature` like any other). It **narrows, but does not close**, the circular-completeness gap — the independent enumeration is itself judgment and can share a blind spot. See `docs/shadow-review.md`.

**Mechanical corroboration:** findings are matched by a `defect_signature` (`file` + overlapping `line_range` + identical `kind`). Corroboration across agents is a stronger calibrator than any single agent's stated confidence.

**Dirty-tree backstop (Phase 3.1/3.2).** Review/analysis agents are *advisory* and contractually must **never mutate the working tree** — their definitions forbid editing working-tree source files, the index, HEAD, or branch state, and any mutation/half-revert verification is performed on a temporary copy made with `mktemp`, never in place. Independently of agent compliance, the shared engine snapshots the tree with `git status --porcelain -z` immediately **before** the Phase 3.1 batch and compares **after** it returns. On an agent-introduced **modification** it records an **Important** finding (attributed to the dispatch, never silently discarded) and restores only the *snapshot delta* — paths clean at snapshot time that became dirty during the dispatch window — (a rename/copy-only or status-byte-only divergence is surfaced in a breadcrumb rather than a formal finding) computed **by path column**, so a path the orchestrator had already modified is left to the human rather than clobbered. The `-z` capture is load-bearing: it emits **unquoted, NUL-delimited** paths, so a spaced or special-character filename is a real pathspec the restore (`git checkout HEAD -- <path>`, from HEAD so a *staged* mutation is undone) can act on rather than silently skip. Both snapshots are rc-checked and fail closed (a failed before-snapshot disables the backstop for that dispatch rather than restoring off an empty baseline; a failed after-snapshot is surfaced as a distinct breadcrumb, not misattributed as a mutation). In the **read-only `/devflow:review` profile** the agents have no write tools, so the snapshots match and the restore never fires; the backstop earns its keep in the write-enabled `/devflow:review-and-fix` and `/devflow:implement` tiers (including the Step 2.6 shadow pass, which re-runs these phases verbatim). **Residuals it does NOT auto-restore:** a **true rename/copy** (status `R`/`C`, which needs index surgery to undo safely — surfaced in a breadcrumb, left for the human) and an agent's further edit to an **already-dirty path that does not change its status byte** (identical `-z` record → the divergence test cannot see it). See [`docs/shadow-review.md`](shadow-review.md).

### Phase 4: Aggregation & verdict
- **4.0** (PR mode) honor the Scope-Acknowledged Findings deferrals via `scripts/match-deferrals.py`.
- **4.1.5 Over-grade advisory annotation** (advisory only — never changes the verdict): the **single source of truth** for the over-grade shape definitions (`/devflow:review-and-fix`'s Step 2.6 calibration gate consumes the same shapes rather than forking them). Before the verdict is computed, the engine scans the findings it will weigh and **flags** any that match an observable over-grade shape — a defect the suite catches RED or that fails closed, a diagnostic-or-cosmetic-only finding with no behavioral fail-direction, or an uncorroborated single-source `Critical`/`Important` from an empirical over-grader (`silent-failure-hunter` / `pr-test-analyzer`). Standalone `/devflow:review` has no fixer to record a calibration, so it appends an advisory "suspected over-grade" note to the flagged finding's report line and **leaves the verdict untouched**: it never demotes a finding, never alters its severity, and never clears or downgrades a REJECT. The note only helps a human reading a bare REJECT distinguish a genuine blocker from a diminishing-returns over-grade. The full flag-and-record gate (which *requires* a recorded `severity-calibrated` evaluation before a flagged finding may drive a shadow-promotion, and still never auto-demotes) remains fix-loop-only.
- **4.2 Verdict** (first match wins): any FAIL → **REJECT**; any INCONCLUSIVE → REJECT; any finding **at or above `devflow_review.verdict_severity_threshold`** (default `critical`) → REJECT; otherwise APPROVE (with caveats/notes as appropriate). The threshold moves **only** this REJECT line — a repo can set it to `important` (Important/Major also blocks) or leave it at the default `critical` (byte-identical to the historical behavior). Read through `config-get.sh` (DevFlow's config resolver) and enum-validated inline in the skill, falling back to the default with a breadcrumb on a bad/absent value (never aborts). Both standalone `/devflow:review` and the fix loop's Phase-3 pass inherit it.
- **4.4** (PR mode only, `/devflow:review`) records a formal GitHub review: **REJECT → `--request-changes`** (blocks merge), clean → `--approve`.

### Per-subagent model & effort overrides
The `devflow_review.agent_overrides` config maps any of the **nine** review subagents (or a `default`) to a `{model, effort}`. Because effort isn't a dispatch-time parameter and per-run overrides must not require editing committed agent/skill frontmatter, DevFlow materializes a per-run `--agents` JSON block at each dispatch (via `scripts/resolve-review-overrides.py`). Effort enum: `low/medium/high/xhigh/max`.

### The fix loop (`/devflow:review-and-fix`)
- **Configurable iteration cap (default 5, `devflow_review_and_fix.max_iterations`).** Each iteration runs the full engine, then fixes findings one at a time (using `devflow:receiving-code-review` principles), runs tests, commits (`fix:`), and continues.
- **Configurable fix-severity threshold (`devflow_review_and_fix.fix_severity_threshold`, default `important`).** The loop routes to the fixer every finding **at or above** the threshold (`critical` > `important` > `suggestion`) and parks the rest as advisory; at the default it fixes Critical + Important/Major and parks Suggestion/Minor (the historical behavior). Set `suggestion` for a more aggressive fixer or `critical` for a conservative one. Its **effective fix set additionally includes every finding that drove the engine's REJECT** under `verdict_severity_threshold`, even below the fix threshold — so no configuration combination produces a REJECT the fixer is configured to ignore. Read through `config-get.sh` and enum-validated inline (same never-aborting fallback as the verdict threshold). A separate `receiving_review.fix_severity_threshold` (default `critical`) governs the re-open bar only when `/devflow:receiving-code-review` is invoked **directly**; the loop never consults it.
- **Pre-fix verification gate (Step 2.5):** single-source claims about external tools are **web-verified** (cap **5 WebFetches/iteration**), Confirmed → fix; Refuted → demote to advisory. This prevents the loop from "fixing" a hallucinated problem.
- **Mechanism-scoped self-authored-claim re-sweep (Step 3 item 3a):** after a fix changes a *mechanism* (a guard, predicate, exclusion, or helper that comments describe), the loop re-dispatches the existing `devflow:comment-analyzer` (no new agent) over every comment describing that mechanism — located by the mechanism's identifiers across the touched files, not limited to the fix's own diff hunks — and treats a comment that still describes the pre-change mechanism as a finding. It covers the changed mechanism within touched files; it is **not** a repo-wide comment audit. See `docs/shadow-review.md`.
- **Pushback tracking:** when a finding is skipped, it's tagged with a `skip_category` (e.g. `claim-quality`, `out-of-scope`, `already-tracked`). The same finding skipped twice → escalate and stop.
- **Fix-delta verification gate (Step 3.5):** after **every** iteration's fix commit, a **blinded subagent** re-reviews **only that iteration's cumulative fix delta** (prior findings/fix decisions/fixer reasoning withheld) to catch a fix-introduced regression — most often a #62/#98 guard whose accepted-input set is wider than its consumer's contract — in the **same** iteration. A surviving Critical/Important finding (after over-grade calibration) routes back into that iteration's fix step (capped at 2 inner attempts, then promoted); the gate and its inner attempts do **not** count toward the cap. Complements the shadow (which audits the whole diff at convergence, and on an `engine_self_modifying` PR also once after iteration 1 via the early trigger); the shadow + post-shadow gate are unchanged by it.
- **Convergence check:** exits early when fixes are small and no new corroborated Critical/Important finding appears.
- **Loop Exit:** runs a **widens-surface guard** and emits a run-scoped **deferrals manifest**; renders a `## Coverage` section and the run/effectiveness telemetry.

---

## 9. Deep dive: shadow review

> **This is one of DevFlow's most distinctive ideas, a great "wow" moment for a video.** Before `/devflow:review-and-fix` declares a clean approval, it **audits its own approval** with a structurally-independent re-review.

**The problem.** A fix loop's iterations *share state* (prior findings, fix decisions, pushback). That shared context biases the loop toward accepting its own earlier conclusions. So a clean approval from the loop is suspect, it might just be agreeing with itself.

**The shadow pass (Step 2.6).** When the tentative verdict is **non-REJECT**, the engine runs **again** with the loop's accumulated state *withheld*, each reviewer prompt is blinded to prior findings and fix decisions. The two results are compared. (A REJECT normally skips the shadow entirely.) On an `engine_self_modifying` PR — the highest-risk diffs in the repo — the shadow *also* fires on an **early trigger**: once after iteration 1, **regardless of that iteration's verdict (including REJECT)**, feeding any new blinded findings into iteration 2 via the same promotion machinery. Non-`engine_self_modifying` PRs keep the convergence-time trigger only. The early pass reuses the same blinded fan-out and is itself uncounted toward the iteration cap (a promoted iteration 2 it spawns counts, like any promotion); if iteration 1's `engine_self_modifying` flag cannot be read it **fails closed** and runs the early audit anyway. See `docs/shadow-review.md`.

**The hard structural constraint (a genuinely interesting engineering story).** A subagent **cannot dispatch its own subagents**: nested agent dispatch is unsupported by the harness. So a single "go run the whole engine" shadow subagent would silently collapse to a degraded single-agent self-check returning a plausible clean APPROVE, *the exact false-convergence the step is meant to prevent.* **The fix:** the *parent* orchestrator runs the shadow fan-out itself, re-running the engine's phases inline and launching every reviewer normally; independence is enforced per-reviewer-prompt instead.

**Honest degradation, coverage is a positive assertion.** A degraded pass must **never** clear a PR. The shadow's `coverage: "full"` is *proven*, not assumed on no-error: the parent computes the expected reviewer roster from the shadow's own diff classification and confirms every dispatched reviewer returned cleanly. Any shortfall → `coverage: "not_verified"` and the verdict is reported **unverified**. A single transient reviewer failure gets exactly **one** targeted re-dispatch; structural or multi-reviewer failures fail closed immediately.

**How the coverage guarantee is enforced.** Concrete guards make the shadow's `coverage: "full"` claim *trustworthy* rather than assumed, so a degraded, lost, or self-narrowed shadow signal can never read as a clean independent audit: a **dispatched-vs-collected 1:1 join** (a reviewer that was launched but whose result is lost or unparseable counts as a shortfall, exactly like one never dispatched); a **block-presence read-back gate** so "shadow agreed" cannot fire on a `coverage: "full"` value that was never actually persisted; a **render-time coverage assertion** that keeps the `APPROVE WITH UNRESOLVED SHADOW FINDINGS` (AWUSF) headline and its Coverage line in lock-step; and a **too-narrow-classification tripwire** that widens the expected and dispatched roster to the union of the shadow's own classification and the loop's last iteration, catching a self-misclassification that would otherwise shrink both rosters yet still read "full." On the consumer side, `/devflow:implement` treats only `APPROVE`, `APPROVE WITH CAVEAT`, and `APPROVE WITH ADVISORY NOTES` as the clean approve-family, and routes AWUSF through one bounded fix+re-review that clears **only** on a verdict that is both clean *and* full-coverage. A non-clean bounded re-review no longer hard-blocks: Phase 3.3 applies a **severity-aware exit** — only a genuine unresolved Critical (or an unparseable/ungradeable verdict) takes the Blocked path, while a residual of advisory/Suggestion/`severity-calibrated` findings **soft-proceeds** (surfaced in the workpad and PR body, PR left review-ready, human merger decides). See `docs/shadow-review.md`.

**Honest calibration (important, don't overclaim).** A clean shadow **narrows** the gap between the loop's self-assessment and an independent review; it does **not close** it. It's one sample of the *same* engine and reviewer roster. The documented evidence: on PR #58, the in-loop shadow agreed with full coverage, yet a subsequent *standalone* `/devflow:review` still surfaced several hardening items. **A separate `/devflow:review` remains the default exhaustiveness check; a clean shadow raises confidence but never waives it.**

**Cost.** The shadow roughly **doubles** a converging run's cost (a full extra engine pass that yields no fixes when it agrees).

---

## 10. Deep dive: the docs suite

DevFlow treats documentation as part of "done." `/devflow:docs` orchestrates three steps in one session, sharing context forward:

1. **`docs-sync-internal`**: ensures every code change on the branch has a corresponding internal-doc update (goal: 100% alignment). Proportional: major changes → comprehensive, trivial → none. Mandatory final step: **verify every factual claim against the codebase** (the single most common cause of inaccurate docs).
2. **`docs-sync-external`**: aligns customer-facing docs against the internal docs (the source of truth), removing confidential/internal-only content. Follows a detailed style guide (AP style, term conventions, etc.).
3. **`docs-release-notes`**: if the change is customer-visible, appends a brief entry (`- **[Category] Short Title**: description. (#PR)`); otherwise skips the release note. Either way, if the branch bumped the version, it reconciles that version's CHANGELOG entry — taking the version from `.claude-plugin/plugin.json` (not the bump commit's subject) and no-opping if no matching `## [version]` section exists (Step 4b).

Supporting skills:
- **`docs-verify <topic>`**: verifies internal docs for one topic against code (codebase = source of truth). Has a `--report-only` mode (no writes) used by `/devflow:create-issue`. Verdicts: `DOCS ACCURATE` / `DRIFT FOUND` / `DOCS MISSING`.
- **`docs-bootstrap-internal`**: stands up an internal-docs tree from scratch, organized **domain-first** (`orders/`, `customers/`) not code-layer-first, flat (one level), quality over quantity (5–10 thorough seed docs, not 50 stubs).
- **`docs-bootstrap-external`**: generates the initial external docs from the internal source of truth.

Doc paths are configurable (`docs.internal`, `docs.external`, `docs.release_notes_file`, `docs.changelog_file`); internal/external steps can be toggled off (`docs.internal_enabled`, `docs.external_enabled`).

**Consistent discipline across all docs skills:** branch diffs use `git diff origin/main...HEAD` (three dots, branch-only changes); bare source paths only (no line numbers, which rot); the generation skills leave committing to the caller.

---

## 11. Deep dive: `/devflow:create-issue`

Turns a rough user story / bug report / feature idea into a well-structured GitHub issue.

> **Core principle (a quotable line):** *"An issue is the output of resolved decisions, not a place to park unresolved ones."*

The skill exists to prevent "option-listing" issues. Steps:
1. **Assess (read-only):** run `/devflow:docs-verify --report-only` on the topic to ground the issue in current behavior.
2. **Clarify until Definition of Ready:** an unconditional **independent-derivation pass runs first on every run** — the orchestrator re-derives the full Definition of Ready (problem/beneficiary, behavioral forks, edge/error cases, acceptance criteria) from the problem and the Step 1 findings *before* weighing the user's supplied criteria, then drives clarification from the delta plus conflicts; user-supplied acceptance criteria are challenged on completeness *and* correctness, so a comprehensive-looking story gets the same scrutiny a terse one does. The pass writes its derived list to an **observable, gitignored artifact** (`.devflow/tmp/issue-derivation-<slug>.md`, deleting any same-slug leftover first so the file can only be *this* run's) before any clarification round; a **gate** — anchored before the first clarification question and, unconditionally, before Step 3 drafting, with a per-round re-check mirroring it — confirms that artifact is present *and* holds this run's derivation (freshness, not mere presence), so a skipped pass is surfaced rather than silently waved through. In a read-only sandbox the write falls back to a visible inline-in-chat block (and on-disk files are distrusted as possible stale leftovers). The guarantee stays an **ordering-based self-check with an observable artifact, not subagent isolation**. The Definition of Ready itself: problem + beneficiary, single coherent scope, one decided behavior per fork, **solution-space expansion before convergence** (independently generate the mechanism space and surface a categorically stronger guarantee class than the user proposed), one implementation approach, concrete testable acceptance criteria. Uses the runner's user-question tool (`AskUserQuestion` on Claude Code, the canonical example; `ask_user` on runners like GitHub Copilot CLI), with batching conditional on the tool and clarification capped at a runner-neutral total-clarifying-question budget.
3. **Draft + no-options gate:** outside an explicit `## 🚫 Blocked` section, no unresolved-decision language ("or", "either", "TBD", "option", "approach A vs B"). Unresolvable decisions go into exactly one Blocked section, never invented defaults.
4. **Review then create:** show the **complete rendered issue** in chat (never summarized), get **explicit confirmation**, then `gh issue create`. After creation, offer to start implementation (which posts the bare `/devflow:implement <n>` comment).

The issue is created **only after the user explicitly confirms**: a pending confirmation is a valid waiting state, not a reason to create.

**A silent non-response is never disengagement.** During Step 2 clarification, a question-tool timeout (`No response after 60s`) or the user stepping away does **not** engage the draft-from-decided / Blocked path — the skill pauses and re-asks the unanswered question in its final chat message rather than proceeding, drafting, or guessing a default. Only an *explicit* reply ("just create it", "you decide", "I don't know") or an exhausted clarification budget of **answered** questions engages that path. This mirrors the Step 4 confirmation gate: with no response, the pipeline stays paused rather than moving on without the user. (The ~18-question budget counts *answered* questions, so silence never consumes it.)

**Visual specification for UI changes.** When Step 2 infers an issue involves user-visible UI changes, it checks the user-provided resources (pasted images, attached files, URLs, design-tool links such as Figma) for an existing screenshot or mockup and records it in a `## Visual Specification` section — embedded when a hosted URL exists, otherwise referenced with a note on how the implementer can obtain it. When none is provided it asks for one; and when the user has none, it **verbally verifies** the visual details — placement & layout, visual states, responsive behavior, design-system match, plus any task-specific dimension — before finalizing the draft. A screenshot is **preferred, not mandatory**: verbal verification is an accepted substitute, and an unresolved placement detail at disengagement flows to the existing `## 🚫 Blocked` section. Non-UI issues skip the whole path and gain no new questions. This is **prose guidance, not a new gate** — inline LLM inference in the same Step 2 clarification that already assesses scope and forks.

**Code exploration, yes, just not the `code-explorer` subagent.** `/devflow:create-issue` *does* explore the codebase, that's precisely what lets it ask deep, well-grounded questions instead of generic ones. Step 1's `/devflow:docs-verify --report-only` surfaces current behavior and the **relevant files**, and the Step 2 clarification reads those (and adjacent code) to find **similar existing patterns and features** and understand **how the new feature would fit**: which is exactly how it surfaces real implementation forks ("where the codebase admits more than one way to build it") and recommends the best option. What it does **not** do is dispatch the heavyweight `devflow:code-explorer` subagent; the exploration is done inline by the orchestrator. The "do not re-explore the whole codebase" rule in Step 3 is a *draft-time* discipline, by then it works from what it already learned, doing only targeted confirming reads. The dedicated `code-explorer` deep dive is reserved for `/devflow:implement` **Phase 2.1**, where the goal shifts from *what/why* to *how*.

---

## 12. Deep dive: the retrospective loop

> **This is DevFlow's "it learns" story, the strongest differentiator for a keynote.** It is an **evaluator/optimizer** self-improvement loop for the `/devflow:implement` automation.

**The idea.** Every bot-authored PR leaves an evidence trail: review comments, post-bot human commits, CI signals, the workpad's final state, and the bot's own `## Devflow Reflection` friction notes. Once a week, `/devflow:retrospective-weekly` reads the accumulated trail, finds **patterns that recur**, and opens a **human-reviewed** PR proposing the smallest change that would prevent the next occurrence, a CLAUDE.md tweak, a skill rewrite, a missing doc, a new lint rule, a tightened issue template. Humans approve or reject.

**Detection (how a PR is selected).** `lib/scan.sh` selects a merged PR for retrospection via a **union predicate** — a PR qualifies when **any** of these holds, deduplicated by number:
- **(a) the reserved `DevFlow` provenance label** — DevFlow stamps the literal `DevFlow` label on every issue and PR it creates (`/devflow:create-issue`, `/devflow:implement` at PR create, Stage B). The label is *created* via the idempotent best-effort `scripts/ensure-label.sh` (`/devflow:init` pre-creates the label at setup so it exists from day one) and *applied* via the shared best-effort `scripts/apply-labels.sh`. Both helpers transport through repo-scoped REST `gh api` calls — `POST /repos/{owner}/{repo}/labels` for creation and `POST /repos/{owner}/{repo}/issues/{n}/labels` for application (a PR is an issue, so the same endpoint applies labels to both) — rather than the GraphQL-resolving porcelain (`gh label create`, `gh issue edit`/`gh pr edit --add-label`) they replaced. The porcelain's org-scoped GraphQL repo resolution needs `read:org`, which repo-scoped tokens (GitHub App installation tokens, fine-grained `repo`-only PATs) lack, so under those tokens the porcelain silently dropped the label; the REST path needs only the `repo` scope. Each helper always exits 0 and leaves a specific stderr breadcrumb on `gh` failure. This path is **author- and branch-agnostic**, so it works in any repo with **zero branch-naming configuration**;
- **(b) a watched author that closes an issue** — a watched-author PR with a non-empty `closingIssuesReferences`. This is the branch-naming-independent fallback that makes detection work even when the label step was skipped (e.g. DevFlow's own `issue-<N>-<slug>` branches, which match no prefix);
- **(c) the configured `implementation_branch_prefix`** — *only* when it is set non-empty (an empty/unset prefix excludes nothing and never degrades to a match-all glob).

The label (a) and closes-issue (b) paths mean the loop can no longer silently no-op when an adopter's bot uses an unrecognized branch prefix.

If any candidate-source fetch or jq-reshape hard-fails while assembling the weekly candidate set (a `gh pr list` error or a reshape failure on the `DevFlow`-label or watched-author batch), the scan sets a degraded flag and **exits non-zero with an `::error::` breadcrumb naming the gh/jq cause** rather than substituting an empty batch and reporting a partial set as "0 new PRs to retrospect" — a partial GitHub outage must not masquerade as a clean no-op (the same fail-loud posture the idempotency read path takes below). In the operator-driven `--prs` ad-hoc mode, a per-PR predicate *evaluation failure* (the jq `select` aborting, e.g. on a non-array `labels` shape) is reported with a distinct `predicate evaluation failed` breadcrumb carrying the jq diagnostic, kept separate from the `matches no retrospection path` breadcrumb that means the PR was evaluated and legitimately excluded.

**The workpad lives on the issue.** `lib/fetch-pr-context.sh` reads the `<!-- devflow:workpad -->` comment from the **linked issue's** comments (where `/devflow:implement` writes it), not the PR conversation thread. From it the bundle derives `workpad_final_status` (stripping only a leading canonical 🚀/🎉/👎 glyph — by the known glyph set, kept in sync with `workpad.py`'s `_STATUS_GLYPHS` — so a multi-word status such as `In Progress` survives intact) and a `reflections[]` array of the `## Devflow Reflection` bullets. The bullets are now grouped by kind under `### ⚠️ Action required` / `### ℹ️ Notes` sub-headings (see the workpad-sections note above); the parser captures every kind bullet — glyph + bold-label prefix and all (useful signal for the retrospective LLM) — excludes the `### ` sub-headings, and parses a legacy flat block identically, so the array's **count and gate behavior are unchanged**; new grouped bullets additionally carry their glyph + label prefix. `lib/cheap-gate.jq` forces LLM analysis of any run that left **at least one reflection bullet** — that self-reported friction is precisely what the loop exists to learn from — and the issue-sourced `workpad_final_status` makes a `Blocked` run gate correctly instead of being mis-read as clean.

**The LLM/heuristic split (a key efficiency claim).** Deterministic scripts handle *all* scanning, fetching, signal computation, gating, pattern math, and git/PR/issue mechanics. The LLM is invoked at **only two genuine-judgment points**:
- **Stage A** (`/devflow:retrospective`), a per-PR retrospective, **only for PRs that fail a mechanical "clean gate."** Clean PRs are processed deterministically at **zero LLM cost.**
- **Stage B** (`/devflow:retrospective-audit`), per-pattern issue-spec drafting.

```
scan.sh
  → fetch-pr-context.sh  (per PR)
    → cheap-gate.jq
      [clean]  → clean-entry.jq   (deterministic, no LLM)
      [not clean] → Stage A: retrospective subagents (≤3–4 concurrent)
  → materialize-retrospectives.sh
  → actionable-patterns.sh  (uses compute-patterns.jq)
    → Stage B: retrospective-audit subagents (return {title, body} specs)
      → meta-issue.sh  (one issue per pattern + overrides.json cooldown)
  → open-state-pr.sh
  → post-status.sh
```

**Stage A** classifies each non-clean PR into a **fixed category vocabulary** (never coins new slugs): `doc-accuracy`, `fabricated-claim`, `outstanding-reject`, `lenient-verdict`, `deferred-verification`, `unmet-acceptance-criteria`, `incomplete-edit`, `convention-violation`, `unverified-assumption`, `issue-quality`, `tooling-gap`, `other`. Categories drive pattern detection.

**Stage B** re-derives the root cause from primary sources (it does *not* trust Stage A's summary), picks the highest-leverage smallest-blast-radius single change to **propose**, does a counterfactual analysis (false positives / over-broad application), and returns a single `{title, body}` issue spec — it makes **no** edits and runs **no** worktree. The orchestrator files exactly one GitHub issue per pattern via `meta-issue.sh` (stamping the `DevFlow` and `Retrospective` labels and recording an `overrides.json` cooldown). A human triages each filed issue and runs it through the normal `/devflow:implement` → review pipeline.

**Propose, don't dispose (a self-governance safeguard).** Stage B never edits the repo. Every actionable pattern — whatever surface its fix would touch (a skill, an agent, `lib/`, `scripts/`, docs, CLAUDE.md, config, or application code) — becomes **one GitHub issue** filed via `meta-issue.sh`, carrying the `DevFlow` and `Retrospective` labels and a re-derived spec of create-issue quality. A human triages it and runs it through the same `/devflow:implement` → review pipeline every other change gets, so loop-proposed engine changes get the same review — not a weaker autonomous-edit path. (Earlier versions auto-opened intervention PRs on a fixed audit branch for "safe" surfaces and only filed issues for engine files; that split, its worktrees, and the old audit retrospection kind are all retired — #152.)

**Data (all in git, append-only ground truth):**
- `.devflow/learnings/retrospectives.jsonl`, one JSON object per processed PR (every record carries a `pr` field).
- `.devflow/learnings/overrides.json`, human-editable map of dismissed patterns.
- Pattern status (`open`/`regressed`/`fixed`/`dismissed`) is computed **on demand** by `lib/compute-patterns.jq`.

**Idempotent:** re-running processes only PRs not already recorded — `lib/scan.sh` reads `retrospectives.jsonl` from the base branch via the GitHub Contents API and subtracts the already-processed PR numbers from the candidate set. A `404` is the legitimate first-run case (the file isn't on the base branch yet) and leaves the processed set empty. Any *other* failure to decode the processed set under `HTTP 200` — an unparseable Contents-API envelope, a base64 decode miss, a `jq` parse failure, a body carrying neither inline content nor a `download_url`, a failed `download_url` fetch, or content that parses but yields zero `pr` records — **fails loud (exit 1) with a specific breadcrumb** rather than collapsing the processed set to empty. A silent collapse would re-queue the entire backlog and create duplicate retrospectives, so genuinely-corrupt state aborts the scan instead. The same guard (`_decode_existing`) covers both the inline `≤ 1 MB` content transport and the `> 1 MB` `download_url` fallback. **Never auto-merges and never auto-implements**: the maintainer merges the state PR manually and triages each filed issue manually — the loop never starts an implement run on its own filings.

---

## 13. The Scope-Acknowledged Findings contract

A structured handoff that prevents a deliberately-deferred Critical finding from being re-raised as a fresh REJECT by the next review run. The handoff, in order:

1. **`/devflow:review-and-fix` Loop Exit** runs a **widens-surface guard** (if the PR diff overlaps the deferred finding's file within ±10 lines, the deferral is disqualified, catches "refactor around a pre-existing bug then defer it"), and emits a **run-scoped** deferrals manifest.
2. **`/devflow:implement` Phase 4.0.5** merges all run-scoped manifests into one slug-level aggregate and files **one follow-up issue per source file** (with a `PR #<N>` cross-link).
3. **`/devflow:pr-description`** renders a Scope-Acknowledged Findings block in the PR body (a human-readable table + a hidden machine payload).
4. **`/devflow:review` Phase 4.0** validates each deferral against **three guards** and demotes matched findings to **Informational** before computing the verdict.

**The three guards (any failure rejects the deferral):** **trusted filer** (PR author in `devflow.allowed_bots`); **mutual cross-link** (the follow-up issue exists, is open, and references the current PR); **widens surface** (re-checked at review time). The contract is repo-agnostic.

---

## 14. The cloud tier: GitHub Actions architecture

Four DevFlow workflows (plus the repo's own `ci.yml`, whose **required** status check is the **`lib + python tests`** job, *not* `CI`, which is only the workflow `name:` and never resolves as a check):

| Workflow | `name:` | Purpose |
|---|---|---|
| `devflow.yml` | `DevFlow` | Light command listener: `/devflow:review`, `/devflow:review-and-fix`, `/devflow:pr-description` (event-driven only) |
| `devflow-runner.yml` | `DevFlow Runner (reusable)` | Reusable read-only runner called by the reviewer |
| `devflow-implement.yml` | `DevFlow (implement)` | Runs `/devflow:implement` on a bare command comment |
| `devflow-review.yml` | `Devflow Review (auto-trigger)` | Auto-runs `/devflow:review` as a PR gate (a required status check) |

**Key architectural facts (the engineering-deck details):**

- **The runner is split into its own file** because GitHub validates a called reusable workflow's permission ceiling against the caller's grant *across the whole called graph, before any `if:` runs*. Keeping the read-only runner separate from the high-privilege command job lets the read-only reviewer call it without a `startup_failure`.
- **Coexists with Anthropic's Claude GitHub App.** DevFlow never creates or overwrites `claude.yml`. Every DevFlow trigger negates `@claude` so the two never double-fire (the *partition invariant*, enforced by tests). Anthropic's app owns plain `@claude` mentions, Q&A, and `/security-review`.
- **Triggers fire on real comments only, never descriptions.** A `/devflow:*` phrase in an issue/PR body or title must never start a run. Trigger text comes solely from comment/review bodies.
- **`devflow-implement.yml` is issues-only.** The heavy `/devflow:implement` listener subscribes to `issue_comment[created]` alone, and its gate `if:` requires `github.event.issue.pull_request == null` (with `scripts/resolve-implement-trigger.sh` re-checking via an `IS_PULL_REQUEST` backstop). Because a PR comment is *also* an `issue_comment` in GitHub's API, this filter is what keeps a comment on a pull request — including the weekly retrospective's audit-report comment, which quotes the literal `/devflow:implement` phrase in prose on the state PR — from ever starting an implement run. `/devflow:review` and `/devflow:pr-description` in `devflow.yml` stay PR-aware and are unaffected.
- **`devflow-review.yml`** triggers on `pull_request` + `pull_request_target` `[opened, reopened, ready_for_review, synchronize]` and `check_run[rerequested]`. It listens on `opened`/`reopened` (not just `ready_for_review`) because a PR opened directly non-draft never emits `ready_for_review`, without those events the required check would never run on such a PR. Bot actors route to `pull_request_target` (so secrets resolve); humans route to `pull_request`, runs exactly once.
- **`finalize_check` job is named `Devflow Review`** so the required-status-check matcher resolves the ruleset context name to a workflow *job* name (otherwise the check never links and the PR's merge state stays BLOCKED).
- **Stall backstop (`devflow_implement.stall_backstop`).** A headless single-shot `claude-code-action` run can end mid-lifecycle yet report `success` — the SDK ends the session the moment the model emits a tool-call-free turn, so a run that stops at (say) the Phase 2→3 boundary leaves the workpad frozen at an interim `Status` while the job goes green. The agent-side terminal-status self-check cannot fire once the session has ended, so a **workflow-level backstop** runs after the `claude` step and keys on the issue workpad `Status` (via `workpad.py status`, **never** PR draft state): a terminal `Status` (🎉/👎) is a no-op, an interim `Status` (🚀) auto-resumes `/devflow:implement <n>` up to `stall_backstop.max_resume_attempts` (default `2`) with a distinct audit comment per attempt, and an exhausted cap or an unreadable status fails the job loud with a distinct comment. `stall_backstop.enabled` (default `true`, safe-direction on any unrecognized value) is the master switch; disabled or absent, the job behaves exactly as before. The decision is a pure, unit-tested helper (`scripts/stall-backstop-decide.sh`) and the comments go through the best-effort repo-scoped REST `scripts/post-issue-comment.sh`, so the backstop can detect-and-fail-loud honestly rather than masquerading a stalled run as green. *(The reusable primitives ship first; the thin workflow-caller step in `devflow-implement.yml` lands in a follow-up, since pushing a `.github/workflows` edit needs a `workflows:write` token.)*

### Vendoring / runtime materialization
- **Why a workspace path, not a marketplace install?** Inside the `claude-code-action` runner, `${CLAUDE_SKILL_DIR}` is unset, the bash sandbox can't read `~/.claude`, and `$`-expansion is blocked, so workflows reference helpers at the literal path `.devflow/vendor/devflow/scripts/…`. The plugin must physically be there when a job runs.
- **Why `.devflow/vendor/` and not `.claude/`?** On every PR, `claude-code-action` runs a security step that `rm -rf`s sensitive paths (including `.claude`) and restores them from the *base* branch, which would wipe a plugin vendored under `.claude/`. `.devflow/vendor/devflow/` is outside every sensitive path and survives.
- **Thin install (default):** the bulky plugin tree is **not** committed; the `vendor-plugin` composite action fetches it at runtime, pinned to `devflow_version` in `.devflow/config.json`. A thin install **refuses to run without a pinned `devflow_version`** (it never silently tracks mutable `main`).
- **Vendored install (`DEVFLOW_VENDOR=1`):** commits the full tree; nothing fetched at runtime.

### Runtime provisioning (the `setup` block)
Before Claude runs, the runner provisions the toolchain in order **Python → Node → PHP → service containers → `install` lines**. Languages are gated by version keys (empty = skipped). Service containers (databases/caches) start via `docker run` and are reachable on `127.0.0.1:<host-port>`. Node dependency caching is automatic when a lockfile is present. `/devflow:init` auto-fills the deterministic parts from detected language markers.

---

## 15. Security model

A strong slide for security-conscious buyers, DevFlow is explicit about its threat model.

- **One secret by default.** The cloud tier needs only `CLAUDE_CODE_OAUTH_TOKEN` (plus the built-in `GITHUB_TOKEN`) — no GitHub App is **required**. An **optional** App (`DEVFLOW_APP_ID` variable + `DEVFLOW_APP_PRIVATE_KEY` secret, with `Contents: write` + `Workflows: write` + `Pull requests: write` + `Issues: write` + `Actions: read`) does two things: it lets the cloud writers edit `.github/workflows/` files (which the built-in `GITHUB_TOKEN` is hard-blocked from), and it puts **every user-visible cloud post under the App identity** — the review agent's progress comment, verdicts, approvals, and rejections (`devflow-runner.yml`), the trigger reactions, and the notice comments — each site minting its own short-lived token downscoped via `permission-*` inputs to exactly what that site does (the review token is `contents: read`, so the review path cannot push). Unset, behavior is unchanged. See `docs/cloud-setup.md`.
- **Authorization gate.** A run only starts if the sender is an allowed bot (`devflow.allowed_bots`) **or** a human in `devflow.allowed_users` (default `*` = any collaborator) **who also holds write/admin/maintain access**. Resolvers fail **closed**.
- **Base-ref trust boundary.** The automated reviewer reads the `provision_env` flag, the `allowed_tools` list, **and** the `setup` block **only from the trusted base branch**, never the PR head. A malicious PR therefore cannot enable provisioning for its own review, grant itself tools, or inject install commands.
- **Deny-list floor (authoritative, enforced at consume-time).** Regardless of config, the runner strips catastrophic-tier tools before appending the build allowlist: tree-mutation tools (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`) and raw-shell/eval/privilege Bash (`bash`, `sh`, `zsh`, `eval`, `exec`, `source`, `sudo`, …). Legitimate entries whose *subcommand* is a deny word are kept (`Bash(docker exec:*)`). Each strip emits a warning; the review continues.
- **Read-only by default.** With `provision_env` off (the default), the reviewer is byte-for-byte read-only, it inspects the diff and cannot compile/lint/test. Turning it on is a documented opt-in that accepts running untrusted PR build code under a write token.
- **Self-trigger guard.** The implement workpad quotes the literal `/devflow:implement` phrase; the resolver declines any trigger text containing the workpad marker so DevFlow can't trigger itself in a loop.
- **Duplicate-run dedupe.** A thread-scoped dedupe ensures only the oldest concurrent `/devflow:implement` run on a thread proceeds.

---

## 16. Observability: efficiency traces & telemetry

DevFlow instruments its own review runs so teams can see which reviewers actually earn their cost.

- **Per-iteration workpads** (`.devflow/tmp/review/<slug>/<run-id>/iter-<N>.json`) record each Phase-3 agent's findings, corroboration counts, and fix decisions, plus per-phase cost telemetry.
- At **Loop Exit**, `/devflow:review-and-fix` derives a per-subagent **effectiveness trace** and classifies each reviewer with a deterministic 4-way taxonomy: **unique-effective** (found a defect no one else did, and it was fixed), **corroborating** (found a fixed defect ≥2 agents agreed on), **noise** (raised findings, none applied), **null** (silent / out-of-scope only).
- One **durable** JSON record per run is written to `.devflow/logs/efficiency/<slug>-<run-id>.json` — keyed by the run's `<run-id>` (the same discriminator that scopes the workpad directory), so it is one file per run and conflict-free across concurrent branches. The run-id key (not a fresh timestamp) is also what lets the persistence backstop be idempotent (next bullet).
- **Non-droppable persistence.** The record and the durable workpad copy survive even when `/devflow:review-and-fix` is driven inline by an orchestrator that skips the Loop Exit bookkeeping: a warn-only **self-check** at Loop Exit flags a dropped persist, and a deterministic `lib/efficiency-trace.sh --persist` backstop re-derives and commits the artifacts from the on-disk `iter-<N>.json` workpads. See [`docs/efficiency-trace.md`](efficiency-trace.md).
- A configurable `efficiency_cut_candidate_min_dispatch` (default 3) governs when a persistently unhelpful agent is flagged as a candidate to cut (consumed by a follow-up cross-run analyzer).
- **Live progress comment:** in PR mode, `/devflow:review` authors a single run-keyed comment that updates incrementally, a blueprint up front, then per-phase results as they land.

All telemetry is gated by config (`devflow_review_and_fix.efficiency_telemetry_enabled`, `devflow_review.live_progress_comment_enabled`, both default `true`) and is **best-effort**: a telemetry failure never aborts the loop.

---

## 17. Configuration reference

The local tier needs **no config**. To customize, `/devflow:init` scaffolds `.devflow/config.json` (JSON, read by a single python3-based resolver, no `yq`/PyYAML/Node prerequisite for config) and a `config.schema.json` your editor uses for autocomplete. Top-level keys:

| Key | Purpose |
|---|---|
| `base_branch` | Review/merge base (default `main`). |
| `claude_model` | Default model (default `claude-opus-4-8`). |
| `devflow_version` | Cloud-tier: git ref the workflows fetch the plugin from (thin install). |
| `devflow.allowed_bots` / `allowed_users` | Trigger authorization (also the trusted-filer allowlist). |
| `devflow.workpad_marker` | Workpad comment marker. |
| `devflow.effort` / `allowed_tools` | Light command path settings. |
| `devflow_implement.effort` / `allowed_tools` | `/devflow:implement` settings. |
| `devflow_runner.provision_env` / `effort` / `allowed_tools` | Automated-reviewer build-environment opt-in + tools. |
| `devflow_review.live_progress_comment_enabled` / `agent_overrides` | Review engine: live comment + per-subagent model/effort. |
| `devflow_review_and_fix.efficiency_telemetry_enabled` / `efficiency_cut_candidate_min_dispatch` | Telemetry. |
| `setup.*` | Cloud-tier runtime provisioning (versions, services, install lines). |
| `docs.*` | Doc paths, enable flags, release-notes file, CHANGELOG file, labels. |
| `devflow_retrospective.*` | Weekly loop settings (watched authors, min occurrences, cooldown, etc.). Detection is by the reserved `DevFlow` label + a closes-issue fallback (see §12); `implementation_branch_prefix` is an **optional** extra match path, not the detection mechanism, and may be left empty. |
| `workflows.*` | Per-workflow enable/disable toggles. |

`/devflow:init` auto-detects languages (Node, Go, Rust, Java, Ruby, PHP, .NET, Make, Docker) and merges matching build/test/lint tools into three independent allowlists, plus the `setup` block, idempotently (your values always win).

Re-running `/devflow:init` (or `install.sh`) also **backfills** newly-added keys into an existing `.devflow/config.json` without clobbering your values. Backfill is add-only, so it cannot propagate a key *removal*; for the one case where that matters — a `devflow_review.agent_overrides` entry pinning Claude Haiku must not carry an `effort` key, which Haiku rejects with HTTP 400 — re-scaffold runs a separate idempotent cleanup that strips `effort` from any Haiku-pinned override (see [review-agent-overrides.md](review-agent-overrides.md)). An already-clean config is left byte-identical.

After scaffolding and the dependency preflight, `/devflow:init` runs one final **advisory project-memory check**: if the repo root has no `CLAUDE.md` it nudges you toward the built-in `/init` (project memory measurably improves DevFlow's review/implement results), and it points any agent-instruction files you already keep for other tools (`.github/copilot-instructions.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`) at `CLAUDE.md` `@`-import reuse. The check is strictly advisory — it never writes or edits any file and never blocks init (which has already succeeded), and stays silent when nothing is actionable.

---

## 18. Installation & updates

**Local tier (one line):**
```bash
claude plugin marketplace add The01Geek/devflow-autopilot \
  && claude plugin install devflow@devflow-marketplace
```
DevFlow declares **zero companion-plugin dependencies** (every external asset it once dispatched is now first-party — see §6), so `/plugin install` resolves on its own with no `claude-plugins-official` prerequisite. PyYAML is a separate, manual prerequisite (`pip install -r requirements.txt`); `/plugin install` never runs `pip`.

**Cloud tier (one line, from repo root):**
```bash
curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/main/install.sh | bash
```
Thin by default (installs workflows, actions, a local marketplace, a config scaffold, and pins `devflow_version`). `DEVFLOW_VENDOR=1` commits the tree instead.

**Updates:** local tier, `/devflow:init` provisions the project `.claude/settings.json` — it registers `devflow-marketplace` under `extraKnownMarketplaces` with `autoUpdate: true` and enables the plugin under `enabledPlugins`, so Claude Code keeps the plugin updated (additive and non-clobbering, idempotent on re-run); it never sets `permissions.defaultMode`. Selectable `auto` mode is provisioned **separately, at user scope, only with explicit consent, and only on a third-party model provider**: `CLAUDE_CODE_ENABLE_AUTO_MODE` is honored only from user scope (`~/.claude/settings.json`) or managed settings, so the project provisioner skips it (writing it there is a silent no-op) and a dedicated helper (`scripts/provision-auto-mode.sh`, run by `/devflow:init`) merges it into `~/.claude/settings.json` after asking the user — making `auto` **selectable, never on** (no `permissions.defaultMode`, plan/model/admin gates still apply), preserving a deliberately-disabled `"0"`, idempotent/atomic/fail-closed, and printing the one-line setting instead of writing if the user declines. The env var has **no effect on the Anthropic API** (auto mode is already available there by default) and only does anything on Amazon Bedrock / Google Vertex AI / Microsoft Foundry, so the whole step is gated on the provider: it runs only when one of `CLAUDE_CODE_USE_BEDROCK`/`VERTEX`/`FOUNDRY` is truthy and is skipped entirely on Anthropic-direct. The gate is two-layer — the skill pre-checks the provider and skips the prompt silently, and `provision-auto-mode.sh --apply` enforces the same check as a deterministic backstop (it leaves the settings file unchanged and exits 0 with a breadcrumb on Anthropic-direct). This is local-tier only — the cloud tier neither needs nor receives a `.claude/settings.json`. Cloud tier, bump `devflow_version` or re-run `install.sh` (re-running only re-stamps `devflow_version` itself when eligible — a hand-set non-SHA value is preserved; see `docs/cloud-setup.md`).

---

## 19. Repository layout

```text
.claude-plugin/
├── plugin.json          # plugin manifest (declares dependencies)
└── marketplace.json     # this repo is its own marketplace
skills/                  # one SKILL.md per skill
agents/                  # checklist-generator / -deduper / -verifier
scripts/                 # branch-for-issue.py, config-get.sh, ensure-label.sh,
                         #   apply-labels.sh, file-deferrals.py, match-deferrals.py, parse-acs.py,
                         #   workpad.py, …
lib/                     # retrospective-loop helpers (*.sh, *.jq), preflight.sh, test/
.github/                 # cloud tier: workflows + composite actions (incl. vendor-plugin)
.devflow/                # config.example.json + config.schema.json (+ learnings/, logs/)
docs/                    # cloud-setup.md, implement-skill.md, workflow-triggers.md,
                         #   efficiency-trace.md, shadow-review.md, review-agent-overrides.md
install.sh               # one-command cloud-tier install/update
```

Skills reference bundled helpers via `${CLAUDE_SKILL_DIR}` so they resolve from any install location. The test suite runs with `bash lib/test/run.sh` (CI runs it on every PR).

---

## 20. Glossary

| Term | Meaning |
|---|---|
| **Workpad** | The single marker-tagged GitHub issue comment `/devflow:implement` maintains as the run's durable progress surface. |
| **Verification checklist** | The list of every verifiable claim a diff makes, generated and then verified against source by the review engine. |
| **`defect_signature`** | The `file` + `line_range` + `kind` tuple used to mechanically corroborate findings across reviewers. |
| **Shadow review** | A structurally-independent re-review run before declaring a clean approval, to audit the loop's self-agreement. |
| **Scope-Acknowledged Findings** | The contract that lets a deliberately-deferred finding be tracked in a follow-up issue instead of re-raised as a REJECT. |
| **Retrospective loop** | The weekly evaluator/optimizer pass that reads merged bot-PR evidence and proposes interventions. |
| **Clean gate** | The mechanical filter that lets clean PRs be processed with zero LLM cost in the retrospective loop. |
| **Thin install** | A cloud-tier install that doesn't commit the plugin tree; it's fetched at runtime, pinned to `devflow_version`. |
| **Vendoring / materialization** | Placing the plugin at `.devflow/vendor/devflow/` so the CI sandbox can reach its helpers. |
| **Partition invariant** | The rule (test-enforced) that DevFlow triggers always negate `@claude`, so DevFlow and Anthropic's Claude app never double-fire. |
| **Local tier / cloud tier** | Skills run in your editor (no infra) vs. autonomous GitHub Actions automation. |

---

## 21. Messaging guide

**Primary positioning.** *DevFlow is the workflow layer that makes agentic coding work on real codebases*, it doesn't just write code, it ships it: spec → plan → code → test → review → fix → document → review-ready PR, with a self-improving loop on top. Where out-of-the-box agents demo well on pet projects and stall on a real ticket in a large production codebase, DevFlow carries that ticket to the finish line.

**Best-fit user.** A developer or team working in a **large, business-grade codebase** (production/enterprise software) who has tried agentic coding and hit the wall where it works on toy projects but can't complete a real ticket, and who is already on Claude Code + GitHub. The angles below also resonate with adjacent audiences.

**One-liner (StoryBrand elevator pitch, customer is the hero, DevFlow is the guide).** *We help developers drowning in half-finished AI pull requests turn a single request into a complete, review-ready PR, so they ship real features on a real codebase without cleaning up after the agent.*

**Three pillars (use as the deck's spine):**
1. **Works on real codebases, not just pet projects.** A one-line feature request → a codebase-grounded ticket → a complete PR ready for your final review, the full-round implementation out-of-the-box agents can't finish on production code. End-to-end, not just code; the steps a one-shot agent skips (tests, review, docs) are exactly the ones DevFlow won't.
2. **Review that fixes what it finds.** A review-and-fix loop that applies the fixes and re-reviews until it approves, on top of independent verification checklists, a panel of specialized reviewers, mechanical corroboration, and a shadow pass that audits its own approval.
3. **It learns.** A weekly retrospective reads its own track record and proposes the smallest fix that prevents the next mistake, humans approve.

**Differentiators worth naming explicitly:**
- "Ship the PR. Not the cleanup." (the hero tagline)
- "Agentic coding that works on real codebases, not just pet projects."
- "Committing code is the halfway point, not the finish line."
- Shadow review, *it audits its own audit*, with honest calibration (narrows the gap, never closes it).
- Self-improvement loop with an LLM/heuristic split (LLM only at two judgment points; everything else is zero-token deterministic).
- Two tiers: works locally with **zero config**, scales to **autonomous** cloud automation with one secret.
- Built on Claude Code's plugin system; ships its full review/discovery/authoring toolchain first-party (hard-forked from Anthropic's `pr-review-toolkit` + `feature-dev` agents and the `superpowers` skills, upstream licenses retained) — **zero companion-plugin dependencies**.
- Security-explicit: base-ref trust boundary, deny-list floor, read-only-by-default reviewer.

**The sales narrative (the argument arc, use it in a pitch, a landing page, or a talk):**

- **Problem.** You've adopted an AI coding agent. It's dazzling on a demo repo, and then you point it at a real ticket in your actual production codebase, and it comes back half-done: wrong patterns, missing tests, stale docs, acceptance criteria unmet. Your engineers now spend *more* time fixing and reviewing the agent's output than the agent saved.
- **The old way.** Babysit the agent prompt-by-prompt, or hand the whole ticket to a senior engineer who does spec → plan → implement → test → review → fix → document by hand, slowly, expensively, and inconsistently, on every ticket.
- **Why now.** AI has made *writing* code cheap. The bottleneck moved to everything around it, planning against real architecture, rigorous review, keeping docs in sync, at scale, on every change. That's precisely where out-of-the-box agents stall.
- **The new way.** DevFlow takes a one-line request, turns it into a codebase-grounded issue through a few sharp clarifying questions, then runs the full `/devflow:implement` lifecycle, plan, architect, implement, auto-generate the test automation it needs, review-and-fix iterations with a shadow pass that audits its own approval, and docs, and hands you a complete PR that meets every acceptance criterion. Then it improves itself every week.
- **Proof.** Independent verification checklists; a panel of specialized reviewers with mechanical corroboration; shadow review (on PR #58 it agreed with full coverage, yet a standalone `/devflow:review` still surfaced hardening items, calibration kept honest); the weekly retrospective that opens its own improvement PRs.
- **The ask.** `claude plugin install devflow`, runs locally with zero config; add one secret to go fully autonomous in CI.

**Honest-claims guardrails (keep marketing accurate):**
- The in-loop shadow review **narrows** the gap to an independent review; it does **not** replace a standalone `/devflow:review`. Don't claim it "guarantees" completeness.
- A human still does the final review and merge, DevFlow gets the PR *ready*, it doesn't auto-merge.
- The retrospective loop proposes interventions; **humans approve or reject**. It never auto-merges its own changes.
- The local tier needs `git`, `gh`, `jq`, and Python 3.11+/PyYAML on PATH; the cloud tier needs `CLAUDE_CODE_OAUTH_TOKEN`.

**Audiences & angles:**
- **Engineering leaders:** consistency, auditability, reduced review burden, telemetry on reviewer effectiveness.
- **Individual developers:** turn a rough idea into a merged PR without context-switching; runs in your editor with zero setup.
- **Security/platform teams:** explicit threat model, base-ref trust boundary, read-only-by-default automation, one secret.
- **AI/ML audience:** the evaluator/optimizer architecture, independent verification, structural-independence in self-review.

**Demo beats for a video (in order):** rough idea → `/devflow:create-issue` interview → confirmed issue #42 → comment `/devflow:implement 42` → watch the workpad update live (🚀) → draft PR appears → review-and-fix loop + shadow pass → docs updated → PR flips to ready (🎉) → the review-gate check posts APPROVE → human merges. Optionally close with a `/devflow:retrospective-weekly` run filing an improvement issue for the next cycle, "it just got better."
```
