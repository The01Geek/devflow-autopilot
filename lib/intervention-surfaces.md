<!--
Shared prompt fragment used by the /retrospective-audit drafting brief (Stage B subagent).
Stage B PROPOSES a corrective change (it files an issue spec; it does not edit). When choosing
the change to propose, the agent considers — but is NOT limited to — these surfaces. Any surface
is a valid proposal, because a human triages the issue and implements it through the normal
/devflow:implement -> review pipeline.
-->

## Candidate intervention surfaces

When the failure pattern recurs, the highest-leverage change to propose could live on any of these surfaces. Pick the smallest blast radius that actually addresses the root cause; do not optimize for "more visible" over "more correct".

### Process / workflow surfaces

- **Prompt extensions** (`.devflow/prompt-extensions/<skill>.md`) — the consumer-owned surface for a purely **additive** skill-behavior change. `scripts/load-prompt-extension.sh` prints this file and skill `<skill>` is instructed to append it verbatim to its own prompt (an absent/empty file is a silent no-op), so a "make skill X also do Y" fix can land here as an append instead of editing the shipped skill body. It is bounded: extensions are **append-only** (they cannot override or delete existing skill prose) and **consumer-local** (they don't change behavior for adopters who never pull this repo's extensions). A *structural* skill change — one that must override existing prose, or one that *must ship in the engine to take effect for adopters* — proposes a change to the engine itself instead. **Check the file's readers before estimating blast radius:** an extension is not always read by one skill. A skill that applies another skill's principles without invoking it loads that skill's extension too (issue #620), so `.devflow/prompt-extensions/receiving-code-review.md` now governs every autonomous `/devflow:review-and-fix` entry — the standalone loop, implement Phase 3 inline, and the Step 2.6 shadow entry — as well as direct reception passes. Editing it to change reception policy therefore reaches unattended loops, not only interactive ones.
- **`/devflow:implement` skill** (`skills/implement/SKILL.md` orchestrator + `skills/implement/phases/phase-N-*.md` reference files) — the orchestrator drives the four-phase lifecycle; the detailed per-phase procedure you would strengthen/check/gate lives in the phase files (the orchestrator `SKILL.md` holds only thin per-phase stubs).
- **`/create-issue` skill** (`skills/create-issue/SKILL.md`) — the issue-quality entry point. If issues themselves are the bottleneck (vague acceptance criteria, missing repro steps, ambiguous scope), this is where to fix it.
- **`/devflow:review` and `/devflow:review-and-fix` skills** — code-review discipline. If review caught a regression too late, the gap belongs here.
- **Phase sub-skills** (`pr-description`, `docs-sync-internal`, `docs-sync-external`, `docs-release-notes`, `docs-verify`) — narrower behaviors invoked by `/devflow:implement`.
- **Issue templates** (`.github/ISSUE_TEMPLATE/`) — when the failure is structural (humans omit the same field every time), the template itself can encode the requirement.

### Knowledge / convention surfaces

- **`CLAUDE.md`** at repo root — durable, agent-loaded conventions. Use sparingly: every rule here is loaded on every run. Strengthen an existing rule before adding a new one.
- **`docs/internal/<feature>.md`** — feature-specific technical context. The `/devflow:implement` skill is told to consult these first; if Claude missed one, the docs may be missing or stale.
- **`docs/external/`** — user-facing docs. Less common as an intervention surface but valid when the failure is documentation drift.
- **Lint rules** (`phpcs.xml.dist`, ESLint configs, etc.) — encode mechanical conventions where a human-readable rule won't reliably stick.

### Code surfaces

- **Application code itself** — when the failure is a real bug introduced by Claude that recurs because the surrounding code makes the wrong path easier than the right one. Refactor the API, rename, or add a guardrail.
- **Library / utility code** — extracting a helper that makes the correct pattern the obvious one (e.g., a `buildOrFilter()` helper if "use OR not IN" keeps recurring).

### Sub-agent surfaces

- **Agents** (`agents/<agent-name>.md`) — specialized contexts called via the Agent tool. If a failure pattern spans the work an agent does (research, design, review), the agent's instructions may be the leverage point.

### High-blast-radius surfaces (flag the second-order effects in the issue)

Every surface is a valid proposal — Stage B files an issue, not a PR, so a human reviews and implements the change through the normal pipeline. But a change to one of these engine surfaces carries extra blast radius on the self-improvement loop itself, so when you propose one, call out the second-order effects in the issue's Counterfactual/Gotchas so the reviewer can weigh them:

- The engine's own files (`skills/**`, `agents/**`, `lib/**`, `scripts/**`, `.claude-plugin/**`) — a change here ships to every consumer.
- `.devflow/learnings/**` — the loop's own ground-truth data files.
- `.github/workflows/claude*.yml`, `.github/workflows/devflow-*.yml` and the composite actions they consume — breaking these cripples the loop.
- `.devflow/config.json` — config changes touch every other workflow.
