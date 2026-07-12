# Execution-file shape record

**What this is.** A dated, observed record of what `claude-code-action`'s
`steps.claude.outputs.execution_file` actually carries, produced by the re-runnable
probe jobs in [`.github/workflows/matcher-probe.yml`](../.github/workflows/matcher-probe.yml)
(issue #437). It exists to settle — with evidence, not recollection — the question the
repo had asserted as settled fact: *can the token/wall-clock cost half of DevFlow's
telemetry be reconstructed from the harness's own output, without the agent's
cooperation?* See [`docs/efficiency-trace.md`](efficiency-trace.md) for why that
question is load-bearing.

**The `execution_file` schema is NOT a public contract.** This record is a *dated
observation of one action version*, not a specification. `scripts/surface-execution-diagnostics.sh`
and `scripts/parse-engine-error.sh` deliberately tolerate three encodings; this record
confirms or narrows that tolerance but must never be used to hard-code a brittle
single-shape parser. Re-run the probe (`workflow_dispatch`) after any `claude-code-action`
or Claude Code CLI upgrade and refresh the table below.

**How each field is recorded (issue #437 AC3/AC4).** For every field, exactly one of:

- `present` — observed in the parsed execution file.
- `absent` — the file parsed **and carried a result event**, but the field was not seen.
- `unavailable` — the field could not be established (the file was absent/empty/
  unparseable, or carried no result event, or the probe run was denied). Per the repo's
  **unknown-is-not-zero** rule, `unavailable` is never collapsed onto `absent` and never
  onto `0`.

The observation is machine-produced by `scripts/extract-execution-shape.sh`, which also
**redacts** the execution file before anything is uploaded: the artifact carries the
structural shape (each object's immediate keys + value *types*) only — every string *value*
leaf is dropped, so no prompt text, repository content, secret, or attacker-controlled
check-run name leaves the run (AC2). (Object keys are the fixed schema field names, emitted
verbatim; the observed schema places untrusted content in value positions, not keys.)

---

## Observation

**Status: OBSERVED.** The `execfile-shape-probe` job ran and its `execution-file-shape`
artifact is the evidence below. **Every field the question turned on is present.** A second
reviewer, given the run URL, reaches the same verdict by downloading the same artifact —
*"the probe ran"* is not the evidence; the artifact's observed contents are.

| Field | Observed | Evidence |
|---|---|---|
| top-level encoding (array / object / jsonl) | **`array`** | `encoding: array` |
| per-message token `usage` | **`present`** | `usage: object`; leaves `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `total_tokens` |
| wall-clock timing | **`present`** | `duration_ms`, `duration_api_ms`, `ttft_ms`, `end_time` |
| `tool_use` events | **`present`** | `tool_name`, `tool_input`, `tool_use_id`, `tool_uses` |
| `subagent_type` on `Task` dispatches | **`present`** | `subagent_type: string` (plus `task_id`, `task_type`, `agents`) |
| `permission_denials` | **`present`** | `permission_denials: array` |

Cost is carried **directly**, which the issue did not even ask for: `costUSD`,
`total_cost_usd`, and a per-model `modelUsage` breakdown.

- **Probe run URL:** https://github.com/The01Geek/devflow-autopilot/actions/runs/29201071531
- **Artifact:** `execution-file-shape` (uploaded by the `execfile-shape-probe` job)
- **Observed on:** `anthropics/claude-code-action@v1`, 2026-07-12
- **Redaction held:** every string leaf in the artifact is rendered as its *type* only
  (`prompt: string`, `text: string`, `command: string`) — no prompt text, repository
  content, or check-run name left the run.

**What this settles.** The cloud harness already emits, with **zero agent cooperation**,
every variable DevFlow's telemetry currently depends on the agent to volunteer: per-phase
tokens, wall-clock, the subagent dispatch roster, and denials. An agent-independent
(class-(c)) cost floor is therefore **buildable on the cloud tier** — the constraint was
never the platform, it was that nobody had looked.

**What it does NOT settle.** The `execution_file` schema is not a public contract, so this
is a *dated observation of one action version*, not a specification — re-dispatch after any
`claude-code-action` upgrade rather than hard-coding these key names into a brittle parser.
And presence of a field is not proof that its values are complete or correctly attributed
per phase; a floor that consumes them must verify attribution separately.

### Stop-hook execution under `claude-code-action` (AC6)

**Observed: `unavailable` (pending).** Whether a `Stop` hook committed to the **base**
branch's `.claude/settings.json` fires under `claude-code-action` is established by the
`hook-probe` job. The probe hook **ships in this PR** (`scripts/stop-hook-probe.sh`,
registered as a `Stop` hook in `.claude/settings.json`), so no operator hand-edit is
required — but the observation is still an inherently **two-step landing**:

1. `claude-code-action` removes `.claude/` and restores it from the **base** branch before
   running, so the `Stop` hook added *in this PR* is restored away for any run against this
   PR and proves nothing — the hook must already be on base for a run to be meaningful. A
   pre-merge "did not fire" must **not** be read as "hooks do not fire" (the reverse
   launder).
2. Therefore the meaningful observation comes **after this PR merges**, when the hook is on
   the default branch: re-dispatch `matcher-probe.yml` via `workflow_dispatch` from the
   default branch. The `hook-probe` job checks for the gitignored
   `.devflow/tmp/stop-hook-probe-fired` marker the hook writes, and records fired /
   did-not-fire with the run URL.

The marker path is a **coupled contract**: `scripts/stop-hook-probe.sh` writes it and
`matcher-probe.yml`'s `hook-probe` job reads it. Renaming it on one side alone would not
fail loudly — it would turn the AC6 probe into a permanent, silent "did not fire".
`lib/test/run.sh` pins both sides to the same literal, and pins that the hook is actually
registered in `.claude/settings.json` (an unregistered hook observes nothing at all).

### Local-tier transcript token shape (AC7)

**Observed: `real` — the local transcript carries GENUINE per-message token counts.**

Established by running the shipped `scripts/stop-hook-probe.sh` against a real local Claude
Code transcript (2026-07-12, Claude Code with `CLAUDE_CONFIG_DIR=~/.claude-3`):

```json
{ "fired": true, "token_shape": "real", "usage_blocks": 196,
  "max_usage_figure": 342272, "transcript_path_present": true }
```

196 `usage` blocks were present and the largest figure was 342,272 — far outside the
0/1 range that would mark streaming placeholders. **This contradicts the widely-reported
claim that transcript token counts are placeholders never backfilled to real values**, and
it is the first hard evidence against `docs/efficiency-trace.md`'s long-standing assertion
that the token/wall-clock cost half is unreconstructable: on the local tier, it demonstrably
is reconstructable from the harness's own output, with no agent cooperation.

**Two limits on what this observation licenses, both deliberate:**

1. **It is the LOCAL tier only.** Whether `claude-code-action`'s `execution_file` carries
   the same figures is a separate question, still `unavailable` pending the first
   `execfile-shape-probe` dispatch. Do not generalize this row to the cloud tier.
2. **Realness is not freshness.** Claude Code's docs warn the transcript is written
   asynchronously and may lag the in-memory conversation, steering `Stop` hooks toward
   `last_assistant_message` instead of parsing it. This probe establishes that the counts
   are *real*, **not** that the final turn's counts have landed by the time a `Stop` hook
   reads them. A floor built on this must measure that lag separately — an under-count from
   a not-yet-flushed tail is a distinct failure mode this row does not clear.

---

## Notes on denied / unestablished results

- **A denied probe is not an observed-false result.** If the artifact upload, the hook
  probe, or a sandbox read is refused, that is recorded as denied/`unavailable` — it never
  becomes "the field is absent" or "hooks do not fire".
- **Re-runnability (AC9).** All three probe jobs are `workflow_dispatch`-runnable so this
  record can be refreshed after a `claude-code-action` upgrade, matching the existing
  matcher-probe contract.
