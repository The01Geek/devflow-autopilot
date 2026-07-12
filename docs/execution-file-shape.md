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

**Status: PENDING FIRST PROBE DISPATCH.** The probe mechanism (three jobs) has landed but
no probe run has been dispatched against this record yet, so — honestly, per the
unknown-is-not-zero rule — every observed field below is `unavailable`. Dispatch
`matcher-probe.yml` (`workflow_dispatch`) and refresh this section with the run URL and the
downloaded `execution-file-shape` artifact's contents. A second reviewer, given the run
URL, must reach the same verdict by reading the same artifact — *"the probe ran"* is not
the evidence; the artifact's observed contents are.

| Field | Observed | Evidence |
|---|---|---|
| top-level encoding (array / object / jsonl) | `unavailable` | no probe dispatched yet |
| per-message token `usage` | `unavailable` | no probe dispatched yet |
| wall-clock timing (`duration_ms` / `duration_api_ms`) | `unavailable` | no probe dispatched yet |
| `tool_use` events | `unavailable` | no probe dispatched yet |
| `subagent_type` on `Task` dispatches | `unavailable` | no probe dispatched yet |
| `permission_denials` | `unavailable` | no probe dispatched yet |

- **Probe run URL:** _(pending first dispatch)_
- **Artifact:** `execution-file-shape` (uploaded by the `execfile-shape-probe` job)
- **Observed on (`claude-code-action` version):** _(record on first dispatch)_

### Stop-hook execution under `claude-code-action` (AC6)

**Observed: `unavailable` (pending).** Whether a `Stop` hook committed to the **base**
branch's `.claude/settings.json` fires under `claude-code-action` is established by the
`hook-probe` job. This is an inherently **two-step landing** and is additionally
**operator-gated**:

1. `claude-code-action` removes `.claude/` and restores it from the **base** branch before
   running, so a `Stop` hook added *in this PR* is restored away and proves nothing — the
   hook must already be on base for a run to be meaningful. A first-run "did not fire" must
   **not** be read as "hooks do not fire" (the reverse launder).
2. In this change the base-branch Stop-hook breadcrumb **could not be committed by the
   implementing agent**: the permission classifier bars an agent from writing `.claude/`
   (a documented structural boundary — the agent cannot widen or alter its own
   `.claude/` config). So an **operator** must add the breadcrumb hook to base's
   `.claude/settings.json` (write a gitignored `.devflow/tmp/stop-hook-probe-fired`
   marker on `Stop`), then re-dispatch `matcher-probe.yml` from the default branch. The
   `hook-probe` job already checks for that marker and records fired / did-not-fire with
   the run URL.

### Local-tier transcript token shape (AC7)

**Observed: `unavailable` (pending, local-tier).** Whether the `Stop` hook's
`transcript_path` JSONL carries real per-message token counts or streaming placeholders is
a **local-tier** check: it needs a real local Claude Code run whose `Stop` payload exposes
`transcript_path`, which is outside a cloud run's sandbox (the cloud implementing agent's
own attempt to read `~/.claude/projects/**` was refused by the sandbox — recorded as
denied, never as observed-false). Claude Code's docs warn the transcript is written
asynchronously and may lag, and steer `Stop` hooks toward `last_assistant_message` rather
than parsing it — so this field is a probe **target**, not an assumption, and nothing is
built on the transcript's tokens on the strength of this issue alone.

---

## Notes on denied / unestablished results

- **A denied probe is not an observed-false result.** If the artifact upload, the hook
  probe, or a sandbox read is refused, that is recorded as denied/`unavailable` — it never
  becomes "the field is absent" or "hooks do not fire".
- **Re-runnability (AC9).** All three probe jobs are `workflow_dispatch`-runnable so this
  record can be refreshed after a `claude-code-action` upgrade, matching the existing
  matcher-probe contract.
