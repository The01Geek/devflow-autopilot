# `/devflow:review-and-fix` subagent effectiveness telemetry

**Skill:** `skills/review-and-fix/SKILL.md` (Loop Exit, *Subagent effectiveness trace*)
**Derivation:** `lib/efficiency-trace.jq` + `lib/efficiency-trace.sh`

When `/devflow:review-and-fix` runs, its fix loop dispatches a lot of subagents per iteration —
up to five Phase-3 review agents plus the Phase-2 checklist verifiers, re-run across as many as
four iterations, plus a shadow pass. This doc records *why* the run now emits a durable
effectiveness record, what that record contains, and how each subagent earns its verdict.

## The problem this closes

The per-iteration workpads under `.devflow/tmp/review/<slug>/iter-<N>.json` already carry the
data needed to answer "which subagents earned their cost on this PR" — `phase3_findings`
(with `agent`, `corroboration_count`, `fix_decision`), `fix_decisions`, and per-phase cost
telemetry (calls / tokens / wall-clock). But `.devflow/tmp/` is **ephemeral**: on a virtual
GitHub runner the whole directory is destroyed at teardown, so the moment a run finishes the data
is gone. Optimization decisions ("is this agent pulling its weight?") were left to guesswork.

At Loop Exit the loop now derives a per-run effectiveness trace, prints it to chat, and writes one
durable, **tracked** record so the data survives teardown and is reviewable after the fact.

## The workpad roster field: `phase3_dispatched`

A `null` verdict — an agent that was dispatched but raised nothing — can only be detected if we
know which agents were *launched*. The findings array alone can't tell a silent agent from one
that was never dispatched (Phase 0.5 gates `pr-test-analyzer` and `type-design-analyzer` on
small/config-only diffs). So each `iter-<N>.json` workpad records a `phase3_dispatched` array: the
Phase-3 agent identifiers actually launched that iteration, captured **after** Phase 0.5 gating.

`null` is then derived as `phase3_dispatched − (agents present in phase3_findings)`. The field is
best-effort: an older or partially-written workpad without it degrades to classifying only the
agents that appear in `phase3_findings`, and the trace flags the gap for that iteration.

## The 4-way effectiveness taxonomy

Each dispatched subagent is assigned **exactly one** verdict per iteration, by these rules
(highest-precedence match wins, so the assignment is total and deterministic):

| Verdict | Meaning | Derivation |
|---|---|---|
| **unique-effective** | Raised a finding that led to an applied fix, and no sibling agent corroborated it. | ∃ finding with `fix_decision == "applied"` **and** `corroboration_count < 2`. |
| **corroborating** | Its finding led to an applied fix, but ≥1 other agent raised the same defect — added confidence, not coverage. | ∃ finding with `fix_decision == "applied"` (and not unique-effective, i.e. `corroboration_count ≥ 2`). |
| **noise** | Its only findings were pushed back as false-positive or web-refuted. | No applied finding; ∃ finding with `fix_decision ∈ {pushed_back, advisory}`. |
| **null** | Dispatched but raised nothing, or nothing that survived to an applied fix or a noise classification (e.g. only deferred findings). | Everything else, including no findings at all. |

`corroboration_count` is sourced from `phase3_findings`; a missing value is treated as `1`
(single-source / unique). The verdict reads `fix_decision` directly off each finding, so the
classification needs no join into `fix_decisions`.

## The rendered trace

`lib/efficiency-trace.sh --mode trace` renders Markdown printed to chat after the Run telemetry
table. Per iteration it shows the count of Phase-3 agents dispatched, the checklist verifiers split
into **lite** and **agent** modes, the fixes applied, and each agent's verdict. Any iteration that
applied **zero** fixes is flagged with a marginal-yield line ("added nothing"), making a wasted
iteration visible at a glance.

## The per-run record

`lib/efficiency-trace.sh --mode record` emits one JSON object written to
`.devflow/logs/efficiency/<slug>-<run-timestamp>.json` — **one file per run** (not an appended
JSONL), which keeps the store conflict-free across concurrent PR branches at merge time. The record
carries:

- `schema_version`, `slug`, `generated_at`, `iterations`.
- `cut_candidate_min_dispatch` — the config threshold (below), carried forward for the follow-up
  cross-run analyzer.
- `per_iteration[]` — dispatch counts, checklist lite/agent split, fixes applied, the
  `added_nothing` flag, and the `agent_verdicts` roster.
- `telemetry[]` — the existing per-phase / per-iteration cost telemetry (calls / tokens /
  wall-clock) lifted out of each workpad, so cost data is no longer lost with `.devflow/tmp/`.

`.devflow/logs/` is a **tracked** directory (mirroring the tracked `.devflow/learnings/`
learnings-store). The run's existing `git add -A` sweeps the record in, and under
`--push-each-iteration` it is committed and pushed, surviving GH-runner teardown.

## Config keys

Both live under `devflow_review_and_fix` in `.devflow/config.json`
(schema in `config.schema.json`, example in `config.example.json`):

| Key | Type | Default | Effect |
|---|---|---|---|
| `efficiency_telemetry_enabled` | boolean | `true` | Master gate. When `false`, the loop renders no trace and writes no file under `.devflow/logs/`. |
| `efficiency_cut_candidate_min_dispatch` | integer | `3` | Minimum dispatch count before an all-null/noise agent is flagged as a cut candidate. Defined here so the config surface is stable; **consumed by the follow-up cross-run analyzer**, not by `/devflow:review-and-fix` itself (the record carries it forward). |

## Non-fatal by design

Derivation and persistence are best-effort: a missing or unreadable workpad, an absent
`phase3_dispatched` field, or a write failure logs a warning and the fix loop continues to its
normal verdict. The trace is observability, never a gate — it must never abort the loop.

## Out of scope (tracked as follow-up)

This feature is scoped to `/devflow:review-and-fix` only. The cross-run analyzer
(`lib/efficiency-report.jq`), the weekly-loop recommendation section, the cut-threshold consumer,
and a thin record for standalone `/devflow:review` are deliberately out of scope.
