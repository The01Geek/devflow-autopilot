# `/devflow:review-and-fix` subagent effectiveness telemetry

**Skill:** `skills/review-and-fix/SKILL.md` (Loop Exit, *Subagent effectiveness trace*)
**Derivation:** `lib/efficiency-trace.jq` + `lib/efficiency-trace.sh`

When `/devflow:review-and-fix` runs, its fix loop dispatches a lot of subagents per iteration —
up to six Phase-3 review agents (four always-on plus two structurally-gated analyzers) plus the
Phase-2 checklist verifiers, re-run across as many as
four iterations, plus a shadow pass (the parent-orchestrated convergence audit — see
[shadow-review.md](shadow-review.md) for its mechanics and the `step_2_6` telemetry shape). This
doc records *why* the run now emits a durable effectiveness record, what that record contains, and
how each subagent earns its verdict.

## The problem this closes

The per-iteration workpads under `.devflow/tmp/review/<slug>/<run-id>/iter-<N>.json` (run-scoped, so
repeated or concurrent reviews of the same PR never clobber each other) already carry the
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

The `engine_self_modifying` override (Phase 0.5) no longer force-dispatches every Phase 3 agent: it
keeps the full checklist and the four always-on agents firing, but `type-design-analyzer` and
`pr-test-analyzer` keep their structural-applicability gates on every profile (`has_new_types` for
the former, the test-relevance predicate for the latter). So on a docs-only / config-only engine PR
those two analyzers are correctly skipped rather than padding the dispatch roster with `null` /
`corroborating`-only runs — which is exactly what made the earlier engine-PR records overstate cost.

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

`/devflow:review-and-fix` now writes the `checklist[]` array (with each item's `verification_mode`)
and the `telemetry` block to every `iter-<N>.json` workpad whenever Phase 1+2 ran — the writer gap
that previously left these unpopulated is closed. As a result `none-recorded` and a null
`telemetry[].phases` are reachable **only** in genuinely degraded cases (no checklist ran, or
telemetry truly uncaptured), never on a normal full-engine run; a `none-recorded` posture on a run
where Phase 1+2 ran is now a real regression worth investigating, not the expected steady state. The
fields remain best-effort and non-fatal: a single missing `<usage>` block is skipped per-source
without dropping the whole `telemetry` block, and a wholly-absent field still degrades gracefully
rather than aborting the loop.

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

**Headless persistence.** `/devflow:review-and-fix` invokes `config-get.sh` and
`efficiency-trace.sh` **directly** (resolving to a `.devflow/vendor/devflow/…` path), the same way
`/devflow:implement` invokes its helpers — never `bash <path>`. Resolved-path allow-list entries
match on the command's leading token after expansion, so a `bash`-prefixed command would start with
`bash`, match nothing, prompt, and be denied on a headless run (silently skipping the trace). Direct
invocation requires `lib/efficiency-trace.sh` to be committed with its executable bit, and **every**
workflow allow-list under which `/devflow:review-and-fix`'s Loop Exit runs to carry
`Bash(.devflow/vendor/devflow/lib/efficiency-trace.sh:*)`. Two workflows qualify, because the loop's
Loop Exit runs on both entry paths:

- `.github/workflows/devflow.yml` — the inline allow-list for the `/devflow:review-and-fix` comment
  path.
- `.github/workflows/devflow-implement.yml` — the heavy `/devflow:implement` path (partitioned out of
  `devflow.yml`, which carries the comment-trigger routing). `/devflow:implement` Phase 3.3 invokes
  `/devflow:review-and-fix --push-each-iteration`, which runs the full Loop Exit, so this workflow's
  allow-list needs the entry too — alongside the `config-get.sh` entry it already carries.

The slim `review` profile in `devflow-runner.yml` is read-only and never runs the Loop Exit, so it
needs no entry.

## Config keys

Both live under `devflow_review_and_fix` in `.devflow/config.json`
(schema in `config.schema.json`, example in `config.example.json`):

| Key | Type | Default | Effect |
|---|---|---|---|
| `efficiency_telemetry_enabled` | boolean | `true` | Master gate. When `false`, the loop renders no trace and writes no file under `.devflow/logs/`. |
| `efficiency_cut_candidate_min_dispatch` | integer | `3` | Minimum dispatch count before an all-null/noise agent is flagged as a cut candidate. Defined here so the config surface is stable; **consumed by the follow-up cross-run analyzer**, not by `/devflow:review-and-fix` itself (the record carries it forward). |

**Acting on the trace.** The telemetry above tells you *which* subagents earn their cost; the
per-subagent `devflow_review.agent_overrides` block is the lever to *act* on it — move a mechanical
pass to a cheaper model / lower effort, or pin a high-value reviewer to a stronger model / higher
effort. The override keys are byte-identical to the `phase3_dispatched` / finding `agent`
identifiers used throughout this doc, so the trace and the override config stay aligned. See
[review-agent-overrides.md](review-agent-overrides.md).

## Non-fatal by design

Derivation and persistence are best-effort: a missing or unreadable workpad, an absent
`phase3_dispatched` field, or a write failure logs a warning and the fix loop continues to its
normal verdict. The trace is observability, never a gate — it must never abort the loop.

## Out of scope (tracked as follow-up)

The cross-run analyzer (`lib/efficiency-report.jq`), the weekly-loop recommendation section, and the
cut-threshold consumer are deliberately out of scope.

(Standalone `/devflow:review` was previously listed here as out of scope; it now produces its own
per-run record and live trace — see **Standalone /devflow:review** below.)

## Standalone /devflow:review

`/devflow:review` (the single-pass engine, no fix loop) produces the same observability as
`/devflow:review-and-fix`, surfaced through a **live progress comment** on the PR and — on a writable
run — a per-run record. Two differences from the fix-loop case:

**Review-mode effectiveness derivation.** Standalone review never applies a fix, so its records have
no `fix_decision`. Each Phase-3 finding instead carries `contributed_to_verdict` (a boolean):
`true` when the finding counted toward the verdict (drove the REJECT, or was a non-deferral-demoted
finding in an APPROVE-with-notes), `false` when Phase 4.0's deferral match demoted it to
Informational. `verdict_for` in `lib/efficiency-trace.jq` selects its **review-mode branch** off the
run-level `source == "review"` (passed as an explicit `$review_mode` argument), *not* off per-finding
field presence — a demoted finding may carry `contributed_to_verdict: false` or omit it entirely, and
keying on presence would mis-route such an agent into the fix-loop branch and downgrade it from
`noise` to `null`. In review mode: `unique-effective` = a contributing finding no sibling corroborated,
`corroborating` = a contributing finding ≥2 agents raised, `noise` = the agent raised findings but
none contributed, `null` = dispatched but silent. The buckets and precedence are
identical to the fix-loop's; only the "did it count?" signal differs. Records produced by
`/devflow:review-and-fix` (which carry `fix_decision`, not `contributed_to_verdict`) keep the
applied-fix derivation unchanged.

**`source` field.** Every record carries `source` — `"review"` for standalone `/devflow:review`,
`"review-and-fix"` (the default when absent) for the fix loop. Both write into the same
`.devflow/logs/efficiency/` store with `pr-<N>-<ts>.json` names, so `source` (not the filename) is
what a cross-run analyzer uses to segment by originating skill.

**Live progress comment + read-only cloud.** In PR mode (and when
`devflow_review.live_progress_comment_enabled` is `true`, the default), `/devflow:review` authors a
`devflow:review-progress` comment incrementally — a blueprint of the phases, then
per-phase results and each Phase-3 agent's findings as they land, finalizing with the verdict, the
full report, and the telemetry summary + effectiveness trace. One such comment is seeded **per review
run**, keyed by a run-keyed marker (`<!-- devflow:review-progress run=<id>-<attempt> -->`) carrying a
link to that job, so a later run never overwrites an earlier run's comment. It reuses
`scripts/workpad.py` via the helper's `--marker` flag (passed as a plain argument so the command still
starts with the allow-listed helper path) rather than a parallel helper. The slim
cloud `review` profile is read-only for the tree but grants `gh api` / `gh pr comment`, so the comment
edits are permitted there; the per-run record **file** write is gated to writable (local/IDE) runs —
under the read-only cloud profile the trace renders into the comment only, and no file/tree write or
`git` is attempted. The two flags compose independently:
`devflow_review.live_progress_comment_enabled` gates the live comment, and
`devflow_review_and_fix.efficiency_telemetry_enabled` gates the embedded telemetry/trace + record.
One combination has no output surface: telemetry **on** with the live comment **off** in a read-only
cloud run — the record file is gated out of cloud and the comment is disabled, so there is nowhere to
put the trace. The skill emits a one-line `::warning::` in that case rather than silently
computing-and-discarding, so the no-op is visible. (In a writable run that combination still writes
the record file.)
