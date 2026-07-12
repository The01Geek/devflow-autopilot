# `/devflow:review-and-fix` subagent effectiveness telemetry

**Skill:** `skills/review-and-fix/SKILL.md` (Loop Exit, *Subagent effectiveness trace*)
**Derivation:** `lib/efficiency-trace.jq` + `lib/efficiency-trace.sh`

When `/devflow:review-and-fix` runs, its fix loop dispatches a lot of subagents per iteration —
up to six Phase-3 review agents (four always-on plus two structurally-gated analyzers) plus the
Phase-2 checklist verifiers, re-run across as many iterations as the configurable cap allows
(`devflow_review_and_fix.max_iterations`, default 5), plus a shadow pass (the parent-orchestrated convergence audit — see
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
or `severity-calibrated` (the defect is real but was over-graded and calibrated down by the over-grade
calibration gate — not a false positive) is deliberately classified **null**, *not* noise — `noise` is
reserved for `pushed_back` / `advisory` (false-positive / web-refuted). The agent wasn't wrong, but it
added no fix to *this* run, so it does not count against it as noise. Any future `fix_decision` value
also defaults to `null` until `verdict_for` is taught about it.

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
`engine_self_modifying`, and `checklist_skipped`; Phase 0.5's fifth flag `detect_all_audit` is
not persisted — it only forces the completeness-critic pass and never shapes the profile). The cross-run analyzer **must segment by
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
`.devflow/logs/efficiency/<slug>-<run-id>.json` — **one file per run** (not an appended
JSONL), which keeps the store conflict-free across concurrent PR branches at merge time. The
filename is keyed by the run's `<run-id>` (the same discriminator that scopes the workpad
directory), **not** a fresh `date` timestamp: this is what lets the `--persist` backstop (below) be
idempotent — the agent's Loop-Exit write and any later `--persist` re-derivation resolve the *same*
path, so a run is never recorded twice. The record carries:

- `schema_version`, `slug`, `generated_at`, `iterations`, and `synthesized` — record-level `true`
  when **any** iteration was reconstructed by `--persist`'s synthesis floor rather than written by
  the loop (see *Non-droppable persistence* below); an agent-written run reads `false`.
- `cut_candidate_min_dispatch` — the config threshold (below), carried forward for the follow-up
  cross-run analyzer.
- `config_fingerprint` — the config-variant fingerprint (issue #431): an object
  `{sha256, partial, salient}` (or `null` when it could not be established), where `sha256` is over
  the canonicalized `devflow_review` + `devflow_review_and_fix` blocks, `partial` is `true` when only
  one of the two blocks exists (the hash covers what exists), and `salient` carries a few
  interrupted-time-series-relevant key values **verbatim** (`verdict_severity_threshold`,
  `fix_severity_threshold`, `max_iterations`). Computed by the wrapper via python3 (a hard preflight
  prerequisite — **no new command head**), it names the config variant that produced the run, which
  is what makes an experiment's interrupted-time-series comparison attributable.
  **`schema_version` decision (issue #431):** the field is additive and **optional** (nullable), and
  **no consumer gates on `schema_version`**, so the record stays at `schema_version: 1` — a bump would
  imply a breaking change this is not. Records predating the field remain valid; the experiment-record
  assembler (below) handles presence/absence uniformly, falling back to
  `git show <merge_sha>:.devflow/config.json` and marking the fingerprint source when the record
  carries none.
- `per_iteration[]` — dispatch counts, `diff_profile` (Phase 0.5 flags — segment cut decisions by
  this), `verification_posture`, checklist lite/agent split, fixes applied, the `added_nothing` flag,
  `phase3_dispatched_present` (so the analyzer can tell a genuinely zero-dispatch iteration from one
  degraded by an absent roster — both show count 0), the `agent_verdicts` roster, `synthesized`
  (whether *this* iteration was reconstructed by the synthesis floor — a strict `== true` of the
  workpad field, so an absent field reads `false`), and `loop_role`
  (`fix` | `promoted`) — each iteration's role in the fix loop, **derived here** from the prior
  iteration's shadow block (iteration 1 → `fix`; iteration N → `promoted` when iteration N−1's
  `shadow.promoted_to_iter_next` is set, else `fix`), preserving any non-empty value the orchestrator
  already persisted into the iter workpad. This derivation is the field's real consumer: the
  per-iteration `loop_role` in `iter-<N>.json` is legibility the orchestrator writes best-effort, and
  the record surfaces it reliably whether or not that write happened.
- `telemetry[]` — the existing per-phase / per-iteration cost telemetry (calls / tokens /
  wall-clock) lifted out of each workpad, so cost data is no longer lost with `.devflow/tmp/`.
  Each entry's `phases` mirrors the workpad's `telemetry` block **verbatim** (unnormalized; `null`
  when the workpad recorded none) — it is a pass-through, not a versioned sub-schema.

A run with zero readable iterations (catastrophic early failure) writes **no record at all** rather
than a contentless skeleton — symmetric with the flag-off contract.

`.devflow/logs/` is a **tracked** directory (mirroring the tracked `.devflow/learnings/`
learnings-store). Under **`/devflow:review-and-fix`**, the Loop Exit persists the record
deterministically in a single dedicated `chore:` commit (alongside the durable workpad copy),
scoped to the `.devflow/logs/` artifacts so it never absorbs unrelated changes — created on
every writable run, **local mode included**, so the record no longer depends on an incidental
future `git add -A` to sweep it in. That commit is **pushed only under `--push-each-iteration`**;
in default local mode it is committed but not pushed, preserving the no-remote-side-effect
property by not pushing rather than by leaving a tracked file uncommitted. Either way the
record survives teardown — whether a cloud runner being destroyed or a local `.devflow/tmp/`
cleanup. (Standalone **`/devflow:review`** has no fix loop and no Loop Exit: its Phase 4.5 record
write is gated to writable runs and swept up by the surrounding run's commits — it does not emit
this dedicated `chore:` commit.)

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
effort. When the trace shows an agent earns its cost on the first pass but adds nothing unique on
later fix-loop iterations, its optional `iterations: "first-only"` key (default-off) drops it from
the Phase-3 roster on `/devflow:review-and-fix` iterations ≥ 2 — a positional cost lever, distinct
from the model/effort levers (see [review-agent-overrides.md](review-agent-overrides.md)). The
override keys are byte-identical to the subagent identifiers the engine dispatches
under: the six Phase-3 keys are the `phase3_dispatched` / finding `agent` identifiers used
throughout this doc, while the three checklist-phase keys (Phases 1/1.5/2) run earlier and so do not
appear in `phase3_dispatched`. Either way the trace and the override config stay aligned. See
[review-agent-overrides.md](review-agent-overrides.md).

## Non-fatal by design

Derivation and persistence are best-effort: a missing or unreadable workpad, an absent
`phase3_dispatched` field, or a write failure logs a warning and the fix loop continues to its
normal verdict. The trace is observability, never a gate — it must never abort the loop.

## Non-droppable persistence (the self-check + `--persist` backstop)

Best-effort persistence has a failure mode: when `/devflow:review-and-fix` is driven
**interactively/inline** by an orchestrator rather than as a discrete end-to-end invocation, the
agent can follow the engine's *substance* (review, shadow, fixes) but silently drop the Loop Exit
*bookkeeping* — the per-iteration workpad write, the record derivation, the durable copy, and the
`chore:` persist commit. Nothing distinguishes "correctly persisted nothing because telemetry was
off" from "silently forgot to persist," so the gap is invisible, and the lost *full* record is not
reconstructed by any shipped backstop (token/wall-clock telemetry is captured live — whether the
harness's own output could reconstruct it is under empirical test, see the cost-half note below and
issue #437; the Layer-3+ synthesis floor below recovers a minimal effectiveness skeleton from the fix
commits, never that detail). Layered
backstops close this, weakest to strongest — the deterministic backstop (Layer 3) and its synthesis
floor (Layer 3+) are the actual guarantee; the others shrink the blast radius and provide a portable
fallback.

**The telemetry splits into two halves with different recoverability, and the split drives the whole
design.** The **effectiveness** data — findings-per-agent, dispatch counts, verdicts, fix decisions —
is in the agent's context during *any* run, including a hand-run; it is lost only because the
`iter-<N>.json` write was optional, so it is made recoverable by turning that write into a
**non-optional obligation** (see Layer 1). The **token/wall-clock cost** half is captured *live* by
the running loop; when a loop is abandoned, no backstop DevFlow currently ships reconstructs it, so
the emit-obligation guarantees the effectiveness half but does **not** promise the cost half — keep
the loop running live to protect it. Whether an *agent-independent* floor **could** reconstruct the
cost half from the harness's own output — `claude-code-action`'s `execution_file` and the `Stop`-hook
transcript — was long asserted here as settled fact ("no backstop can reconstruct it"), but that
assertion was never measured. Issue #437 replaced the assertion with a re-runnable probe
([`.github/workflows/matcher-probe.yml`](../.github/workflows/matcher-probe.yml)) whose **observed**
results are recorded in [`docs/execution-file-shape.md`](execution-file-shape.md): read that shape
record — not this sentence — before deciding whether an agent-independent cost floor is buildable.

**The first measurement already refutes the strong form of the old claim.** On the **local** tier the
`Stop`-hook transcript was observed (2026-07-12, via `scripts/stop-hook-probe.sh`) to carry **real**
per-message token counts — 196 `usage` blocks, largest figure 342,272 — not the streaming
placeholders it was assumed to hold. So "no backstop *can* reconstruct the cost half" is **false as
stated**: locally the data is right there in the harness's own output, with no agent cooperation. What
remains true is the weaker, honest form: *no backstop DevFlow currently **ships** reconstructs it* —
which is a gap in what we built, not a law of the platform. Two things are still genuinely open, and
neither is settled by the local row: whether `claude-code-action`'s `execution_file` carries the same
figures on the **cloud** tier (`unavailable` pending the first `execfile-shape-probe` dispatch), and
whether the transcript's **tail has flushed** by the time a `Stop` hook reads it (realness is not
freshness — the docs warn the transcript lags). Until both are answered, keep the loop running live to
protect the cost half — but stop repeating that reconstructing it is impossible.

**Layer 1 — wording (portable, agent-executed).** The SKILL.md Loop Exit persistence steps are
marked **mandatory on every writable run**, and a `## Common Mistakes` entry names the
interactive-drop failure mode so a future orchestrator does not silently skip them. The
per-iteration `iter-<N>.json` emit specifically is a **non-optional obligation on every iteration,
regardless of how the loop was executed** — whether `review-and-fix` ran as a `Skill` invocation or
was **hand-run via direct `Agent` dispatch** on a degraded path — and it is written **with the Write
tool, never a shell `>`/heredoc redirect** (which the cloud sandbox denies into `.devflow/tmp`). This
is what keeps the effectiveness half recoverable even when the instrumented loop is left; a cloud
`claude-code-action` permission/sandbox denial is never license to abandon the loop. (This asymmetry
is worth noting: the read-only `review` runner runs under `--permission-mode acceptEdits`, but the
`/devflow:implement` job deliberately does **not** — so the implement seam relies on single-statement
leading-token helper forms and the Write tool for scratch, not a broadened permission grant.)

**Layer 2 — self-check + incremental capture (portable, agent-executed).**
- *Incremental capture, fused to the fix commit.* Each `iter-<N>.json` is written **at Step 3
  item 6's fix-commit moment** — capture `fix_commit_sha`, then Write, as one step, so an
  inline-driven loop has no seam between "fix landed" and "record exists" (Step 3 item 7 is the
  authoritative specification of the record's shape and fields) — not batched at Loop Exit. A
  dropped Loop Exit therefore still leaves the workpads on disk for Layers 2/3 to derive from,
  shrinking the blast radius from "everything" to "just the final derive+commit."
- *Self-check.* `lib/efficiency-trace.sh --self-check --workpad-dir DIR --slug SLUG` is run at Loop
  Exit on a converged writable run. If the run wrote **zero** `iter-*.json` workpads, or produced no
  effectiveness record at `.devflow/logs/efficiency/<slug>-<run-id>.json`, it emits a loud
  `::warning::` naming exactly what was not persisted (and points at `--persist` as the recovery).
  It **additionally validates each `iter-<N>.json`'s field set**: for every iter workpad missing a
  field in the single-source `ITER_EXPECTED_FIELDS` set (the iter schema's top-level fields minus
  `shadow`, which Step 2.6 appends later and is legitimately absent), it emits a `::warning::` naming
  the field and the iter file — turning a silently-dropped inline-persist field into a visible signal.
  A workpad carrying `synthesized: true` (written by the Layer-3+ synthesis floor, below) is a
  recognized degraded class validated against its **own** minimal set (`ITER_SYNTH_EXPECTED_FIELDS`:
  `iter`, `fix_commit_sha`, `fix_files`, `loop_role`, `synthesized`) rather than the full set — so a
  truncated synthesized record still warns instead of validating silently. And the zero-workpad
  warning names the **targeted** recovery command (`--persist --workpad-dir DIR --slug SLUG` — the
  form immune to discovery-mode synthesis skips) rather than implying there is nothing left to
  persist.
  It **warns, never blocks** — it never writes, never commits, never changes the verdict, and always
  exits 0 (a malformed/unparseable/unreadable iter file is skipped rather than aborting the pass; that
  case is breadcrumbed by the `--persist`/`--mode` parse paths). It is **silent** when telemetry is
  disabled (no record is expected) and on a read-only run (the cloud `review` profile, where SKILL.md
  never invokes it — there is no Loop Exit there).

**Layer 3 — deterministic backstop (harness-executed, the actual guarantee).**
- *`lib/efficiency-trace.sh --persist`.* Derives the effectiveness record **and** stages+commits it +
  the durable workpad copy from whatever `iter-*.json` workpads exist on disk, in one scoped
  `chore:` commit. With `--workpad-dir`/`--slug` it persists one run; without them it **discovers**
  every `.devflow/tmp/review/<slug>/<run-id>/` run dir and persists each — a dir holding
  `iter-*.json` directly, a workpad-less dir via the Layer-3+ synthesis floor below (skipping
  standalone `/devflow:review` runs — `source == "review"` — which have their own Phase 4.5 path).
  It is **idempotent**: the record filename is run-id-keyed and presence-based (an existing record is
  never re-derived, so its `generated_at` can't churn), the durable copy is a content-idempotent
  `cp`, and the commit is pathspec-scoped with a `git diff --cached` guard — so a re-run produces no
  new commit and never an empty one. Best-effort: every failure logs a `::warning::` and it always
  exits 0. The durable copy runs on every writable run (not telemetry-gated); the record is
  telemetry-gated.
- *`Stop` hook (local-tier only).* The project's `.claude/settings.json` registers a `Stop` hook
  that runs `--persist` after the agent's turn ends — when the run is already complete, so persisting
  there is **non-blocking by construction**. `--persist`'s discovery + presence-based idempotency *is*
  the "review-and-fix activity detected but no committed record exists" gate: it is a clean no-op when
  there is nothing unpersisted. It is best-effort (`|| true`); a failure never fails the session. The
  hook config (for this repo; adopters point the command at the vendored
  `.devflow/vendor/devflow/lib/efficiency-trace.sh`). The `Stop` array carries a **second,
  unrelated** command — `lib/implement-stop-guard.sh`, the local-tier terminal-status backstop
  documented in [`implement-skill.md`](implement-skill.md). The two are independent: only the
  `--persist` entry takes `|| true`, and the guard deliberately does **not**, because its
  blocking exit code 2 must reach the harness:

  ```json
  {
    "hooks": {
      "Stop": [
        {
          "matcher": "",
          "hooks": [
            { "type": "command", "command": "bash lib/efficiency-trace.sh --persist || true" },
            { "type": "command", "command": "bash lib/implement-stop-guard.sh", "timeout": 15 }
          ]
        }
      ]
    }
  }
  ```

  > **Note on this repo's `.claude/settings.json`.** Writing `.claude/` is a privileged,
  > self-modifying action. The boundary an agent cannot cross is widening its own
  > `permissions.allow` allowlist — that is what stops an agent granting itself new
  > capabilities. The **hook wiring** in this same file is not covered by that boundary:
  > editing the `hooks` block is an ordinary file write, so a `/devflow:implement` run may
  > add or change a hook entry (and the classifier may still deny it, in which case the run
  > routes the change to a human rather than skipping it silently). It ships committed in
  > this repo (`.claude/settings.json`); the `--persist` mode it calls and the cloud-tier
  > guarantee land in the same wiring.
- *Cloud-tier wrapper.* **`Stop` hooks are local-only**: `claude-code-action` `rm -rf`s and restores
  `.claude/` from the **base** branch before installing plugins, so a PR branch's `.claude/` hook is
  discarded for that PR's own cloud run, and the cloud guarantee must **never** depend on the hook.
  Instead the cloud writable workflows — **`.github/workflows/devflow.yml`** (the
  `/devflow:review-and-fix` comment path's `command` job) and **`.github/workflows/devflow-implement.yml`**
  (the `/devflow:implement` Phase 3.3 `--push-each-iteration` path) — invoke `--persist`
  unconditionally (`if: always()`, best-effort) in a workflow step **after** `Run Claude Code`,
  pushing only if a recovery commit was created. (`devflow-runner.yml` is the read-only `review`
  profile — it runs no fix loop and cannot write the tree, so it is intentionally **excluded**: there
  is nothing to persist there.) Because a GitHub App token cannot self-modify `.github/workflows/`,
  a maintainer committed this step after `Run Claude Code` in each of those two workflows; it now
  ships committed in both:

  ```yaml
  - name: Persist review-and-fix observability artifacts (backstop)
    if: ${{ always() }}
    run: |
      set +e
      HELPER=.devflow/vendor/devflow/lib/efficiency-trace.sh
      [ -f "$HELPER" ] || { echo "::warning::observability backstop: $HELPER missing; skipped"; exit 0; }
      git config user.name "github-actions[bot]" 2>/dev/null || true
      git config user.email "41898282+github-actions[bot]@users.noreply.github.com" 2>/dev/null || true
      before=$(git rev-parse HEAD 2>/dev/null)
      bash "$HELPER" --persist
      after=$(git rev-parse HEAD 2>/dev/null)
      if [ -n "$after" ] && [ "$before" != "$after" ]; then
        git push || echo "::warning::observability backstop: push of persisted artifacts failed; commit is local-only"
      fi
      exit 0
  ```

- *`/devflow:implement` Phase 3.3 inline backstop (agent-executed).* `/devflow:implement` drives
  `/devflow:review-and-fix` **inline in the orchestrator's own context** (Phase 3.3), so its Loop Exit
  runs in-context and can be dropped exactly like any other interactive/inline drive. To close that
  seam without waiting for a harness-tier caller, `phase-3-review.md` runs `--persist` directly
  (resolved via the portable skill-dir anchor as `…/../../lib/efficiency-trace.sh`, best-effort `|| true`) the moment
  the inline loop returns — regardless of verdict, before the verdict branches. It runs `--persist`
  **twice, targeted first**: this orchestrator drove the loop inline and *does* hold its
  `<slug>`/`<run-id>`, and persisting its own run by explicit `--workpad-dir`/`--slug` identity is
  immune to every discovery-mode synthesis skip (multi-slug ambiguity, not-latest ordering) **and**
  to the lone-stale-foreign-dir shape, where discovery would misattribute this branch's fix commits
  to a leftover slug and the sha exclusion would lock the misattribution in. An argument-less
  discovery call then covers every *other* leftover run dir on disk; both calls' stderr land in one
  capture. When the slug/run-id are genuinely not held (the inline loop died before `RUN_ID` was
  computed), the targeted call is skipped with a workpad note recording that, and discovery plus the
  detector below remain the loud floor — never guessed values. The "no inputs" detector is **this-run-scoped**, not a
  whole-tree presence check: before driving the loop, Phase 3.3 snapshots the `iter-*.json`
  already on disk, then after `--persist` returns it diffs (`comm -13`) the current tree against
  that snapshot — only files that are genuinely NEW this run count. This is deliberate: a
  whole-tree presence check would let a leftover `iter-*.json` from an earlier local run mask a
  real loss on this run. Because the Layer-3+ synthesis floor writes its reconstructed
  `iter-*.json` under the same `.devflow/tmp/review/` tree, the detector counts synthesized files
  as recovered inputs — a zero-workpad run that synthesis recovered does **not** fire the gap
  reflection. Only when the diff is empty — the inline loop wrote no per-iteration workpad **and**
  synthesis also recovered nothing (no unrecorded fix commit, a failed search, failed writes, or a
  discovery-mode skip; `--persist`'s own warnings name which when a candidate dir was visited at
  all) — is the telemetry genuinely lost, and Phase 3.3 records a `dropped-failed` reflection
  naming the gap rather than letting it vanish. The phase anchors both
  the snapshot and the detector on the git top-level the **same** way `efficiency-trace.sh` does, so
  it scans the exact `.devflow/tmp/review/` tree `--persist` scans and never fires a false "telemetry
  lost" reflection from a cwd-relative divergence (if the pre-loop snapshot is itself missing, the
  detector degrades to whole-tree presence and emits a distinct `::warning::` naming that degrade,
  since it can then mask a real loss behind a leftover file). The detector counts NEW `iter-*.json`
  regardless of `--persist`'s `source == "review"` skip: at this inline seam the review-and-fix loop
  just driven is what writes the tree, so a foreign review-sourced dir being the sole new occupant is
  not a reachable in-flow shape. The no-new-inputs case above only catches a dropped *Loop Exit*
  (the loop wrote nothing at all); it does not by itself catch the sibling failure mode where the
  loop *did* write `iter-*.json` but `--persist`'s own record derivation/write step then failed —
  its jq-derivation and mkdir failure paths both leave a `record not written` breadcrumb on stderr,
  and its disk/permission write-after-mkdir failure path (ENOSPC/EROFS/quota/perms) leaves a
  differently-worded `...failed (disk/permission); not persisted for...` breadcrumb — all while
  still exiting 0 by design. Phase 3.3 captures the `--persist` invocation's stderr and greps it for
  both breadcrumb shapes (a single-literal grep here would silently miss the disk/permission path),
  recording a second, independent `dropped-failed` reflection when either fires, so a record
  derivation/write failure is surfaced even when inputs existed — this is deliberately narrower than
  every conceivable `--persist` failure surface; a record written to disk but not yet git-committed
  (a separate staging/commit failure path) is a distinct, lower-priority gap tracked on the issue's
  workpad rather than covered here. And because the `APPROVE WITH UNRESOLVED
  SHADOW FINDINGS` path can drive a **second**, separate inline `review-and-fix` invocation (the
  bounded re-review), Phase 3.3 re-runs the whole snapshot-then-backstop procedure — a fresh
  this-run baseline before, the persistence check after — around that second invocation too, so it
  is not left unguarded at the same seam the first invocation's backstop protects.

**Layer 3+ — synthesis floor (part of `--persist`): reconstruct a fully-dropped run from its fix
commits.** When `--persist` finds a run dir with **zero** `iter-*.json` (targeted or discovered), it
no longer stops at "nothing to derive": it reconstructs **minimal** iteration records from the
branch's fix commits, so even a run whose every workpad emit was dropped still contributes an
effectiveness floor. The floor is exactly that — a floor, **never license to skip the item-6 emit**:
it recovers only the skeleton below and none of the checklist / findings / per-phase cost detail the
real record carries, which is unreconstructable once dropped.

- *Commit-subject selector (coupled two-site invariant).* Commits are selected by the subject
  template `fix: address review findings (iteration {N})` — **written** by
  `skills/review-and-fix/SKILL.md` Step 3 item 6 and **parsed** by `lib/efficiency-trace.sh`
  (`FIX_COMMIT_SUBJECT_PREFIX`). `lib/test/run.sh` pins both sites; rewording the subject means
  editing both in the same commit. The commit range is `<base>..HEAD`, where the base ref prefers
  `origin/<base>` over the local base branch (routinely stale in worktrees — a stale local base
  would widen the range to sweep already-merged history and misattribute an old PR's fix commits);
  `<base>` is config `.base_branch`, default `main`, and an unresolvable base fails closed with a
  breadcrumb naming the tried value. Adversarial subject shapes are each breadcrumbed and skipped,
  always exit 0: a fix-loop-family subject without the `(iteration N)` suffix, trailing text after
  the suffix or a missing `)`, and a non-numeric iteration token; a leading-zero token is normalized
  (`01` and `1` are the same iteration), and a duplicate N keeps the **earliest** commit
  (`git log --reverse`).
- *Synthesized-record shape.* Each synthesized `iter-<N>.json` carries exactly `iter`,
  `fix_commit_sha`, `fix_files` (from `git diff-tree`; **`null` when that derivation fails** —
  unestablished, deliberately distinct from a genuine empty commit's `[]`), `loop_role: "fix"`, and
  `synthesized: true`. `lib/efficiency-trace.jq` surfaces the marker at every level: per-iteration
  and in each `per_iteration[]` entry as a strict `== true` (an absent or malformed field reads
  `false` — agent-written workpads carry no such field, so real records read `synthesized: false`),
  and record-level as `any(…)` — `true` when **any** iteration was reconstructed, the key a
  cross-run analyzer uses to weight a reconstructed record differently from an agent-written one. A
  synthesized-only run renders normally in both `--mode trace` and `--mode record`, with
  `verification_posture: "none-recorded"` (no checklist was ever captured — correctly flagged as
  the instrumentation gap it is).
- *Double-count defenses.* Three guards keep a fix commit from being counted into two runs'
  records or misattributed across runs: (a) **sha-level exclusion** — any commit already recorded
  as a `fix_commit_sha` by another run's `iter-*.json`, in the live tmp tree **or** the committed
  durable copies under `.devflow/logs/review/`, is skipped; the exclusion is checked **before**
  duplicate-N dedupe so an excluded commit never consumes its iteration number and shadows this
  run's own commit; (b) among one slug's workpad-less dirs, only the **lexicographically-latest**
  run-id synthesizes — earlier ones breadcrumb and decline; (c) workpad-less dirs spanning
  **multiple slugs** in one discovery pass are **all declined** — slug ownership of the branch's
  commits is not derivable offline, so the ambiguity fails closed for every candidate, each
  breadcrumb naming the targeted `--workpad-dir` escape hatch. Documented residual windows: a run
  whose every workpad copy (tmp *and* durable) was deleted after its record was derived; a **lone**
  stale foreign slug's workpad-less dir when the current run left no tmp dir at all (a single
  candidate is offline-indistinguishable from the legitimate run — the phase-3.3 targeted-first
  call is the mitigation); within one slug, a stale earlier run-id that is the only candidate
  receives the record (right slug, wrong run-id; the sha exclusion still prevents any
  double-count); and a workpad-less dir left by a standalone `/devflow:review` run synthesizes
  under the default `source: "review-and-fix"` (a synthesized workpad carries no `source` field).
- *Honesty ladder (unknown is never collapsed onto "found none").* `synthesize_iter_workpads`
  returns **0** (wrote ≥1 record), **2** (the selection ran and found no unrecorded matching
  commit), **3** (the search **could not run** — an uncreatable target dir, an unresolvable base
  ref, or a failed `git log` enumeration, each with its own producer breadcrumb naming the tried
  value), or **4** (commits *were* selected but every record write failed, with per-commit
  warnings). `persist_one` dispatches each arm to a distinct `::warning::`, plus an unknown-rc arm
  so a future rc drift is never reported as "no commits were found."
- *Unsubstituted-placeholder guards.* A `<placeholder>` identity is refused loudly (best-effort
  exit 0 preserved) on **both** routes it can arrive by: the **argv** route (`--workpad-dir` /
  `--slug` containing `<` or `>` — a verbatim-run backstop fence) and the **basename-derived**
  route (a literal `<slug>/<run-id>` *directory* reaching discovery mode is refused by
  `persist_one`'s twin guard). Without these, a non-substituting run would fabricate a placeholder
  identity, synthesize the branch's real fix commits under it, and the sha exclusion would then
  lock the misattribution in — a placeholder identity is never fabricated.
- *Telemetry gating.* `efficiency_telemetry_enabled: false` skips synthesis entirely — a
  synthesized workpad exists **only** to feed the (disabled) effectiveness record, so fabricating
  one would commit telemetry artifacts to a repo that switched telemetry off. The durable copy of
  **real** workpads stays ungated, as before.

This guarantees **persistence of whatever telemetry was captured**. It does **not** guarantee
*capture* of `tokens` / `wall_clock_s` — those come from `<usage>` blocks the agent reads live and no
post-hoc tool can recover them if the agent never recorded them (the incremental writes + the
self-check warning maximize capture, but it remains irreducibly agent-dependent).

### Shadow synthesis floor (issue #426)

`--persist` carries a second, narrower synthesis floor for the **shadow** block, sibling to the
iter floor above. The shadow pass (`/devflow:review-and-fix` Step 2.6) appends a `shadow` block to
the triggering iter's workpad, but that block can drop entirely (the issue-304 drop shape), leaving
a promotion with no record of the shadow that produced it. When an `iter-<N>.json` carries **no
`shadow` block** but the run holds **promotion evidence** — an `iter-<N+1>.json` with
`loop_role: "promoted"`, meaning iteration N's shadow promoted new findings into iteration N+1 —
`synthesize_shadow_markers` writes a minimal marker into `iter-<N>.json`'s `shadow` field:

- *Synthesized shadow-marker shape.* Exactly `shadow_synthesized: true` and
  `promoted_to_iter_next: true` (the promotion linkage). `--self-check` validates a
  `shadow_synthesized: true` block against this minimal set (`SHADOW_SYNTH_EXPECTED_FIELDS`) as a
  recognized degraded class — a truncated synthesized marker still warns, exactly like a truncated
  synthesized iter record; a real (agent-written) shadow block carries no `shadow_synthesized` key
  and is never validated by this branch (it stays unvalidated, as before).
- *Never overwrites an agent-written block.* The floor writes only when `.shadow` is `null` — the key
  missing, or present with an explicit JSON `null` (both are "no block"); an
  existing block — agent-written or already synthesized — is left untouched. It is telemetry-gated
  (a disabled repo gets none) and runs before the durable copy, so a synthesized marker is committed
  alongside the workpads it annotates. Best-effort: any failure warns and continues, never aborting
  `--persist`.
- *Every failure arm names its own cause.* The marker is merged in via a temp file plus `mv`, and
  both write arms surface the underlying tool's error text — the failing `jq`'s message, and `mv`'s
  own errno (read-only mount, `ENOSPC`) — rather than discarding it, so a floor that could not write
  is diagnosable rather than merely reported. On either failure the source `iter-<N>.json` is left
  untouched and the temp file is removed: no half-written marker, no orphaned `.shadowtmp`.
- *Stated limitation — promoted shadows only.* The floor recovers a dropped shadow block **only**
  when promotion evidence survives. A clean outcome-1 shadow whose block dropped leaves no promotion
  evidence to synthesize from, so it is unrecoverable here — the fused Step 2.6 emit (mandatory on
  both termination paths, authored with the Write tool) is the primary fix and this floor is its
  backstop, not its equal. Like the iter floor, it recovers **attribution, not cost**: the
  `step_2_6` token/wall figures are captured live and no shipped backstop reconstructs them after the
  fact. Whether the harness's own `execution_file`/transcript could supply an agent-independent cost
  floor is no longer asserted here as settled — it is under empirical test by the issue #437 probe,
  with the observed result recorded in [`docs/execution-file-shape.md`](execution-file-shape.md).
  Older records without the marker remain valid.

## The unified experiment record (`experiment-records.jsonl`)

`scripts/build-experiment-records.py` (issue #431) is the **join** that makes the operator's
experiment program measurable: it assembles one line per merged PR into the tracked
`.devflow/learnings/experiment-records.jsonl`, joining what a run **spent** (the efficiency records
above) to whether its PR came out **clean** (the review outcome). It is a **reader** of every
historical store shape — python3 stdlib plus `gh`/`git` subprocesses (the `DEVFLOW_GH` env-read
pattern, no probe; native `git` subprocess per the #295 Windows rule) — and runs on the
**local/interactive retrospective tier only** (invoked by `skills/retrospective-weekly/SKILL.md`
between Step 5 (Materialize) and Step 7 (State PR), best-effort — its failure logs a stderr breadcrumb
carried into the Step 9 status report as a blocker note and never blocks the retrospective;
`lib/open-state-pr.sh` then commits the store on the state PR so `main` is clean entering Stage B).

Each line carries its own `schema_version` (currently `1`, independent of the efficiency record's)
plus the PR's identity — `pr`, `issue`, `branch`, `merged_at`, `merge_commit_sha` — and then the
joined fields:

- **`efficiency_runs[]`** — **all** matching efficiency records for the PR as a per-run list with
  per-run `cost` (never newest-wins, since discarding earlier runs' cost corrupts a cost-vs-outcome
  experiment). Both slug families are resolved: `pr-<N>` directly, and the branch slug from the
  retrospective entry's `branch` field (with a `gh` lookup fallback). Each entry also carries
  `synthesized`, `iterations`, `run_id`, `config_fingerprint`, and `telemetry_complete`.
- **`telemetry_complete`** (per efficiency run) — `true` **only** when the record is not synthesized,
  every iteration carries non-null token telemetry, and no degradation breadcrumb is present. Analyses
  exclude degraded records **by this flag** rather than silently averaging them in.
- **`retrospective`** — the PR's retrospective entry (the `branch`-slug join key and PR metadata).
- **`verdict`** — selected by **artifact shape**: the first completed PR review whose body matches the
  `## Verdict:` contract **regardless of bot identity**; when none exists, the run-keyed
  `devflow:review-progress` comment's `## Verdict:` line is the fallback; when neither exists the
  verdict is `null` (the #403 shape). The parser strips both the full-report `(summary)` suffix and
  the pr-review stub suffix `— full report in PR comment` the engine appends when a live progress
  comment is active, so the stored verdict is the bare token (`APPROVE` / `REJECT` / …) on every
  surface. The `provenance.verdict` field names which arm resolved it — `pr-review`,
  `progress-comment`, `progress-comment-degraded` (the comment supplied the verdict *because* the
  authoritative reviews call could not be established, so the value may predate the final reviewed
  HEAD — degraded, not merely second-choice; the reason is spelled out in `provenance.notes`),
  `unparseable` (a `## Verdict:` marker was present but its line did not parse), `absent`, or one of
  the four **unestablished** tags below.
- **`important_finding_count`** — parsed from the run-keyed progress comment joined via
  `review.commit_id` == the comment's `**Reviewed HEAD:**` line (the engine's own join — see
  `skills/review/SKILL.md`, the normative source). `null` with provenance when no progress comment
  joins to the review's commit_id (absent or superseded by a later run's comment), its findings
  section is unparseable, or the comment could not be established.
- **`permission_denials_count`** — read from the `Devflow Review` check-run `output[summary]`
  `permission_denials_count:` line (issue #431) for PRs after that change; for historical PRs it falls
  back to best-effort check-run **annotation** retrieval (provenance `check-run-annotation`), whose
  bias is recorded in `provenance.notes` (annotations carry only **positive** counts, so a historical
  zero is indistinguishable from unavailable, and expired logs yield nothing). Carried **verbatim** in
  every path — `unavailable` stays `unavailable`, and **no code path coerces an unestablished count to
  `0`** (the repo's unknown-is-not-zero contract, end to end).
- **`config_fingerprint`** — from the efficiency record's `config_fingerprint` when present, else
  recomputed from `git show <merge_sha>:.devflow/config.json` (records predating the field);
  `provenance.config_fingerprint` marks the source (`efficiency-record` / `merge-commit-config` /
  `absent`, plus the unestablished tags below). When a PR's runs carry **disagreeing** fingerprints
  (its runs straddled a config change), the record-level value is `null` with source
  `mixed-across-runs` rather than first-wins: this field is the experiment's *attribution key*, so
  silently stamping such a PR with the older variant would misattribute its outcome. Nothing is lost —
  the per-run fingerprints remain in `efficiency_runs[]`.
- **`provenance`** — a map naming which sources joined (and a `notes` list), so a `null` field is
  always distinguishable from an unqueried one.

**Unestablished is not absent.** `absent` is the strong claim *"we looked and it genuinely was not
there"*. Four tags mean the opposite — the join could not be measured at all — and they are never
collapsed onto `absent` (the provenance-dimension analogue of the value-level unknown-is-not-zero
contract). They apply to every gh-sourced field above:

| Tag | Meaning |
| --- | --- |
| `fetch-failed` | The call ran and did not yield a usable answer — a non-zero `gh` exit, or an exit-0 response whose body was unparseable. |
| `no-repo` | The repo could not be resolved, so no *join* call was attempted (the single `gh repo view` probe that resolves it having already failed). |
| `no-sha` | The PR metadata that supplies the query key (head / merge sha) was itself unestablished, so this join is unestablished *by cascade*. |
| `unparseable` | The artifact was retrieved, but the value could not be read out of it (a `## Verdict:` marker whose line does not parse; a fingerprint envelope carrying no `sha256`). |

The normative list is `PROVENANCE_UNESTABLISHED` in `scripts/build-experiment-records.py`; a record is
rejected at construction if any field governed by one of these tags carries a non-null value, so an
unqueryable join can never publish a measurement.

**Idempotent** (one line per PR, keyed by PR number — a re-run replaces, never duplicates) and
**incremental** (it processes merged PRs absent from the store plus any passed via `--prs`, never a
full-history sweep per invocation). **Missing-source-tolerant — for the *inputs***: every join input
is optional, so an absent source yields null fields plus a provenance tag, and an unreadable *input*
store emits a stderr breadcrumb and simply does not join. Never a fabricated value.

**But tolerance is a claim about the inputs, not about the exit status.** The *destination* store
(`experiment-records.jsonl`) is read **strictly**, because the assembler REWRITES it rather than
appending: tolerating a corrupt line there would silently delete every record it could not parse, and
`lib/open-state-pr.sh` would commit the truncation. The run **exits 2** — writing nothing — in that
case, and also when a PR's merge state could not be **established** (a `gh` outage: excluding it
silently would lose it for good, since only stored or retrospective-listed PRs are ever re-selected)
or when any candidate failed to assemble. Records that *did* assemble are still written on a partial
failure, so a non-zero exit means "some PRs are missing from the store," not "nothing was written."
A PR **observed** to be unmerged is a clean exclusion and exits 0 — observed-unmerged and
unestablished are never conflated in either direction.

**CLI surface.** Invoked bare, the assembler resolves everything from the repo root and needs no
arguments — that is how `/devflow:retrospective-weekly` calls it. The flags exist for re-runs and
tests: `--prs <n,n,…>` forces specific PRs into the candidate set (the re-run path after a partial
failure, since an unestablished PR never enters the store and so is not re-selected on its own),
`--dry-run` assembles and reports without writing the store, and `--repo-root` / `--store` /
`--retrospectives` / `--efficiency-dir` override the four resolved paths. Exit codes are **0**
(everything selected was assembled, or cleanly excluded as observed-unmerged) and **2** (see above);
there is no exit 1.

**Abandoned-run exclusion and its cost-side bias.** The record is keyed on **merged** PRs, so a run
whose slug never produced a merged PR (an abandoned branch) contributes **no cost row** — the cost side
therefore carries a documented survivorship bias (abandoned-run cost is invisible to the join). This is
deliberate: the experiment measures cost-vs-outcome for PRs that shipped.

## Out of scope (tracked as follow-up)

The cross-run analyzer (`lib/efficiency-report.jq`) and the weekly-loop recommendation section remain
open work this issue does **not** supersede — the cut-candidate aggregation that consumes
`cut_candidate_min_dispatch` / `phase3_dispatched_present` is still unbuilt. Issue #431 added the
`experiment-records.jsonl` **join** (above), which is the measurement substrate those analyzers will
read; it does not itself compute cut candidates or weekly recommendations.

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
`.devflow/logs/efficiency/` store, so `source` (not the filename) is what a cross-run analyzer uses
to segment by originating skill. (The two skills key the filename differently — review-and-fix by
`<run-id>` for its `--persist` backstop's idempotency, standalone review by timestamp — but since
`source` is the segmentation key, the filename scheme is free to differ.)

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
