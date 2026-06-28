<!--
Shared prompt fragment used by the /retrospective-audit drafting brief (Stage B subagent).
When proposing a corrective intervention, the agent considers — but is NOT limited to — these surfaces.
-->

## Candidate intervention surfaces

When the failure pattern recurs, the highest-leverage fix could live on any of these surfaces. Pick the smallest blast radius that actually addresses the root cause; do not optimize for "more visible" over "more correct".

### Process / workflow surfaces

- **Prompt extensions** (`.devflow/prompt-extensions/<skill>.md`) — the in-scope, consumer-owned surface for a purely **additive** skill-behavior change. `scripts/load-prompt-extension.sh` prints this file and skill `<skill>` is instructed to append it verbatim to its own prompt (an absent/empty file is a silent no-op), so a "make skill X also do Y" fix lands here as a normal in-scope edit instead of touching the excluded `skills/**` body or filing a meta-issue. This directory is **not** on the out-of-scope/meta-issue list below — `lib/check-excluded-path.sh` does not match it. It is bounded: extensions are **append-only** (they cannot override or delete existing skill prose) and **consumer-local** — meaning *applied via this repo's extension surface rather than the shipped skill body* (it doesn't change behavior for adopters who never pull this repo's extensions), **not** "only this repo benefits." So a *structural* skill change — including one that must reach two skills through one file, like the shared `/devflow:review` engine — or any engine-general rule that *would materially benefit adopters and is expressible as engine prose* routes to the meta-issue for upstream promotion rather than a repo-local extension.
- **`/devflow:implement` skill** (`skills/implement/SKILL.md`) — the orchestrator that drives the four-phase lifecycle. Strengthen a phase, add a check, tighten a gate.
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

### Out-of-scope surfaces (these route to a meta GitHub issue for human design review)

The limit is **design-review**, not writability — locally all paths are writable. If the analysis points at one of these as the root cause, the orchestrator routes to a meta GitHub issue (`[devflow-retrospective] meta: <pattern-tag>`) and appends a `dismissed: meta-plugin-issue` override for the pattern. The subagent returns an `excluded: true` JSON object and makes no working-tree edits.

- The engine's own files (`skills/**`, `agents/**`, `lib/**`, `scripts/**`, `.claude-plugin/**`) — the plugin must not edit itself without human review
- `.devflow/learnings/**` — data files
- `.github/workflows/claude*.yml`, `.github/workflows/devflow-*.yml` — breaking these cripples the loop; human design review required
- `.github/actions/read-project-config/**`, `.github/actions/setup-project-env/**` — the composite actions consumed by the devflow workflows; modifying them risks breaking the self-improvement loop
- `.devflow/config.json` — config changes touch every other workflow

Everything else — CLAUDE.md, other skills, docs, agents, application code, the `/create-issue` skill, lint configs, issue templates — remains in scope.
