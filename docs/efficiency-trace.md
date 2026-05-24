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
telemetry (calls / tokens / wall-clock). But `.devflow/tmp/` is **ephemeral** scratch in every
run — gitignored and routinely cleaned out locally, and destroyed wholesale when a cloud GitHub
runner is torn down. Either way, the moment a run finishes the data is liable to vanish.
Optimization decisions ("is this agent pulling its weight?") were left to guesswork.

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
| **null** | Dispatched but raised nothing, or nothing that survived to an applied fix or a noise classification. | Everything else, including no findings at all. |

A finding whose only outcome is `deferred` (the defect is real but out-of-scope / already-tracked)
is deliberately classified **null**, *not* noise — `noise` is reserved for `pushed_back` / `advisory`
(false-positive / web-refuted). The agent wasn't wrong, but it added no fix to *this* run, so it does
not count against it as noise. Any future `fix_decision` value also defaults to `null` until
`verdict_for` is taught about it.

`corroboration_count` is sourced from `phase3_findings`; a missing value is treated as `1`
(single-source / unique). The verdict reads `fix_decision` directly off each finding, so the
classification needs no join into `fix_decisions`.

## The diff profile and verification posture

A `null` verdict means different things on different diffs. On an app-code change with real bugs, a
silent `code-reviewer` may genuinely have under-earned its cost; on a config-only or
engine-self-modifying jq/docs change, the *same* silence is correct — that reviewer's domain simply
wasn't in the diff. Aggregating raw `null`-rate across diff shapes would systematically recommend
cutting the generalist agents, which is backwards. So each iteration carries a `diff_profile`: the
engine's Phase 0.5 classification (`small_diff`, `config_only`, `has_new_types`,
`engine_self_modifying`, and `checklist_skipped`). The cross-run analyzer **must segment by
`diff_profile`** before drawing any cut conclusion — a `null` on a diff outside the agent's domain is
not a cut signal.

The same `diff_profile` drives a **verification posture** that keeps a healthy cost-saving choice
from looking like a gap. The orchestrator deliberately avoids dispatching verifier subagents when it
doesn't need them — resolving substring claims via the cheap orchestrator-direct `lite` probe, or
skipping Phase 1+2 entirely when Phase 0.5 classifies the diff as low-risk (`small_diff` +
`config_only`). That is good behavior, not absence of work, so the trace names it explicitly rather
than printing a bare "0 verifiers":

| Posture | When | Trace line |
|---|---|---|
| `skipped-intentional` | Phase 0.5 bypassed Phase 1+2 (small_diff + config_only) | "Checklist: skipped by Phase 0.5 (…) — verifier subagents intentionally not dispatched for a low-risk diff." |
| `skipped-failure` | checklist generation failed | "Checklist: generation failed — proceeded with review agents only." |
| `lite-only` | items resolved via `lite` probes, zero agents dispatched | "Checklist verifiers: N lite (orchestrator-direct), 0 agent — … without dispatching verifier subagents (cost-saving, by design)." |
| `agent-only` / `mixed` | verifier subagents dispatched | "Checklist verifiers: N lite, M agent." |
| `none-recorded` | no skip reason and zero items recorded | "Checklist verifiers: none recorded for this iteration." (the one posture that flags a genuine instrumentation gap) |

## The rendered trace

`lib/efficiency-trace.sh --mode trace` renders Markdown printed to chat after the Run telemetry
table. Per iteration it shows the diff profile, the verification posture (above), the count of
Phase-3 agents dispatched, the fixes applied, and each agent's verdict. Any iteration that applied
**zero** fixes is flagged with a marginal-yield line ("added nothing"), making a wasted iteration
visible at a glance.

## The per-run record

`lib/efficiency-trace.sh --mode record` emits one JSON object written to
`.devflow/logs/efficiency/<slug>-<run-timestamp>.json` — **one file per run** (not an appended
JSONL), which keeps the store conflict-free across concurrent PR branches at merge time. The record
carries:

- `schema_version`, `slug`, `generated_at`, `iterations`.
- `cut_candidate_min_dispatch` — the config threshold (below), carried forward for the follow-up
  cross-run analyzer.
- `per_iteration[]` — dispatch counts, `diff_profile` (Phase 0.5 flags — segment cut decisions by
  this), `verification_posture`, checklist lite/agent split, fixes applied, the `added_nothing` flag,
  `phase3_dispatched_present` (so the analyzer can tell a genuinely zero-dispatch iteration from one
  degraded by an absent roster — both show count 0), and the `agent_verdicts` roster.
- `telemetry[]` — the existing per-phase / per-iteration cost telemetry (calls / tokens /
  wall-clock) lifted out of each workpad, so cost data is no longer lost with `.devflow/tmp/`.
  Each entry's `phases` mirrors the workpad's `telemetry` block **verbatim** (unnormalized; `null`
  when the workpad recorded none) — it is a pass-through, not a versioned sub-schema.

A run with zero readable iterations (catastrophic early failure) writes **no record at all** rather
than a contentless skeleton — symmetric with the flag-off contract.

`.devflow/logs/` is a **tracked** directory (mirroring the tracked `.devflow/learnings/`
learnings-store). The run's existing `git add -A` sweeps the record in, and under
`--push-each-iteration` it is committed and pushed, surviving teardown — whether that is a
cloud runner being destroyed or a local `.devflow/tmp/` cleanup.

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
