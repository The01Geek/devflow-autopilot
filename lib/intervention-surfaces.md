<!--
Shared prompt fragment used by the /audit-implementations drafting brief (Stage B subagent).
When proposing a corrective intervention, the agent considers — but is NOT limited to — these surfaces.
-->

## Candidate intervention surfaces

When the failure pattern recurs, the highest-leverage fix could live on any of these surfaces. Pick the smallest blast radius that actually addresses the root cause; do not optimize for "more visible" over "more correct".

### Process / workflow surfaces

- **`/implement` skill** (`skills/implement/SKILL.md`) — the orchestrator that drives the four-phase lifecycle. Strengthen a phase, add a check, tighten a gate.
- **`/create-issue` skill** (`skills/create-issue/SKILL.md`) — the issue-quality entry point. If issues themselves are the bottleneck (vague acceptance criteria, missing repro steps, ambiguous scope), this is where to fix it.
- **`/review` and `/review-and-fix` skills** — code-review discipline. If review caught a regression too late, the gap belongs here.
- **Phase sub-skills** (`pr-description`, `docs-sync-internal`, `docs-sync-external`, `docs-release-notes`, `docs-verify`) — narrower behaviors invoked by `/implement`.
- **Issue templates** (`.github/ISSUE_TEMPLATE/`) — when the failure is structural (humans omit the same field every time), the template itself can encode the requirement.

### Knowledge / convention surfaces

- **`CLAUDE.md`** at repo root — durable, agent-loaded conventions. Use sparingly: every rule here is loaded on every run. Strengthen an existing rule before adding a new one.
- **`docs/internal/<feature>.md`** — feature-specific technical context. The `/implement` skill is told to consult these first; if Claude missed one, the docs may be missing or stale.
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
- `.github/actions/read-project-config/**`, `.github/actions/dedupe-pr-events/**`, `.github/actions/get-app-token/**` — the three composite actions consumed by the devflow workflows; modifying them risks breaking the self-improvement loop
- `.github/project-config.yml` — config changes touch every other workflow

Everything else — CLAUDE.md, other skills, docs, agents, application code, the `/create-issue` skill, lint configs, issue templates — remains in scope.
