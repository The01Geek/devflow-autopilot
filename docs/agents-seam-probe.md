# Cloud per-agent-effort seam probe — evidence of record (issue #610)

This is the evidence artifact of record for the **cloud per-agent-effort seam spike**
(issue #610, carried from #554). It records whether the spike-gated *applied arm* — the
one that would compose a resolved per-agent `effort` into a process-start `--agents`
agent-definition the platform reads at launch — may ship, and it is the human-readable
counterpart to the deterministic verdict the probe workflow emits.

The precedent is [`.github/workflows/matcher-probe.yml`](../.github/workflows/matcher-probe.yml),
whose observed tables are the recorded, human-adjudicated evidence of record for the
permission matcher. Like that probe, this one is **repo-internal** (not shipped to
consumers by `install.sh`) and **human-dispatch** — its result is recorded here.

## What the probe establishes

The probe (`.github/workflows/agents-seam-probe.yml`) runs a real `claude-code-action`
session whose `claude_args` carry a startup `--agents` JSON defining a `seam-probe-agent`
subagent with `effort: low`, while the session itself runs at `--effort high`. It then
establishes two facts:

| Fact | What it asks | How it is measured | Confidence |
|---|---|---|---|
| **(i) forwarding** | Does `claude-code-action` forward a startup `--agents` JSON from `claude_args`, so a subagent type defined only there is dispatchable? | **Deterministic.** The agent-definition makes the subagent emit `SEAM_PROBE_FORWARDED_OK`, which can appear in the execution file only if the block was forwarded and the type recognized. | High — a harness-recorded `tool_use`. |
| **(ii) governance** | Does an `effort` on that startup agent-definition govern the reasoning effort of a runtime Agent-tool dispatch of that subagent type? | **Not auto-measurable.** Effort is not a harness-recorded field, so the only signal is the subagent's own `SEAM_PROBE_EFFORT=<effort>` self-report. A `low` self-report (vs. the session's `high`) is evidence for fact (ii). | Low — model self-report; must be **adjudicated by a human**. |

## Decision rule

The verdict is computed deterministically from the action's execution file by the
unit-tested helper [`scripts/agents-seam-probe-verdict.py`](../scripts/agents-seam-probe-verdict.py)
(the model's prose is never the measurement):

| Verdict | Meaning | Applied arm ships? |
|---|---|---|
| `SEAM_PROVEN` | Fact (i) forwarding proven **and** a human adjudicated fact (ii) as GOVERNED (passing `--adjudicated-governed`). | **Yes** — implement the applied arm; flip the cloud per-agent row off honest fallback. |
| `SEAM_FORWARDED` | Fact (i) proven; fact (ii) not yet adjudicated. | No — honest fallback stays until a human adjudicates the recorded self-report. |
| `SEAM_UNPROVEN` | The subagent type was dispatched but no seam marker appeared (the `--agents` block was not forwarded). | No — honest fallback stays. |
| `INCONCLUSIVE` | Nothing conclusive was measured (execution file absent/unparseable, or no dispatch attempted). | No — re-run the probe. |

**The applied arm ships only on `SEAM_PROVEN` — i.e. only when BOTH facts are proven.**
This is issue #610 AC1's contingency: *"The per-agent applied arm is implemented only if
the probe proves both facts; otherwise the cloud per-agent row is honest fallback
identical to local, and no per-agent effort application code ships."*

## How to dispatch

From the default branch, run the **Agents seam probe** workflow via
`workflow_dispatch` (it is human-dispatch only — no PR trigger). Read the run's **job
summary** for the verdict table. A human then:

1. Confirms fact (i) from the deterministic `forwarded(marker)` evidence.
2. Adjudicates fact (ii) from the recorded `SEAM_PROBE_EFFORT=<effort>` self-report — a
   `low` report (matching the agent-definition, not the session's `high`) supports fact
   (ii). Corroborate across a couple of runs; a self-report is a weak signal.
3. Records the outcome in the **Recorded result** section below.
4. Only if BOTH facts hold, re-runs the verdict helper with `--adjudicated-governed` to
   obtain `SEAM_PROVEN`, and files/implements the applied-arm follow-up.

## Recorded result

**DISPATCHED — highest recorded verdict `SEAM_FORWARDED`. Fact (ii) is NOT adjudicated,
so the seam is NOT proven, the cloud per-agent-effort row remains honest fallback
identical to local, and no per-agent effort application code ships** — still exactly
AC1's "otherwise" branch.

The probe was dispatched **nine times on 2026-07-21**, every run via `workflow_dispatch`
from `main` at commit `93e5cd13`. Eight completed with conclusion `success`; one
(`29872281102`) was `cancelled` by this workflow's own `cancel-in-progress` concurrency
group when the next dispatch started, but its `if: always()` verdict step still produced
a complete measurement, so it is listed and counted separately below.

Every figure in this section is a **past-time snapshot** of runs that cannot be
re-derived once the logs age out — the checked-in-literal exemption in `CLAUDE.md`'s
"prefer generated evidence" convention. Do not machine-render it; that would overwrite
the record.

| Date (UTC) | Run link | Verdict | Fact (i) | Fact (ii) self-report | Adjudication |
|---|---|---|---|---|---|
| 2026-07-21 21:47 | [29871350774](https://github.com/The01Geek/prflow/actions/runs/29871350774) | `SEAM_UNPROVEN` | marker not recorded | _unobserved_ | not adjudicated |
| 2026-07-21 21:49 | [29871446151](https://github.com/The01Geek/prflow/actions/runs/29871446151) | `SEAM_FORWARDED` | **marker recorded** | `low` | not adjudicated |
| 2026-07-21 21:50 | [29871519987](https://github.com/The01Geek/prflow/actions/runs/29871519987) | `SEAM_UNPROVEN` | marker not recorded | _unobserved_ | not adjudicated |
| 2026-07-21 22:02 | [29872281102](https://github.com/The01Geek/prflow/actions/runs/29872281102) (run `cancelled`) | `SEAM_FORWARDED` | **marker recorded** | `low` | not adjudicated |
| 2026-07-21 22:02 | [29872320341](https://github.com/The01Geek/prflow/actions/runs/29872320341) | `SEAM_FORWARDED` | **marker recorded** | `low` | not adjudicated |
| 2026-07-21 22:04 | [29872398980](https://github.com/The01Geek/prflow/actions/runs/29872398980) | `SEAM_UNPROVEN` | marker not recorded | _unobserved_ | not adjudicated |
| 2026-07-21 22:04 | [29872451024](https://github.com/The01Geek/prflow/actions/runs/29872451024) | `SEAM_UNPROVEN` | marker not recorded | _unobserved_ | not adjudicated |
| 2026-07-21 22:05 | [29872503054](https://github.com/The01Geek/prflow/actions/runs/29872503054) | `SEAM_FORWARDED` | **marker recorded** | `low` | not adjudicated |
| 2026-07-21 22:06 | [29872570287](https://github.com/The01Geek/prflow/actions/runs/29872570287) | `SEAM_FORWARDED` | **marker recorded** | `low` | not adjudicated |

### What the runs measured

**Fact (i) — forwarding: positively established, in 4 of the 8 successful runs (5 of 9
including the cancelled one).** In those runs the top-level session recorded a `Bash`
`tool_use` whose input is `printf '%s\n' 'SEAM_PROBE_FORWARDED_OK SEAM_PROBE_EFFORT=low'`.
Per the decision rule above, that marker cannot be produced unless the startup `--agents`
block was forwarded and `seam-probe-agent` was recognized, so a single such observation
establishes fact (i); four independent ones corroborate it.

**The four `SEAM_UNPROVEN` runs are not counter-evidence — they are instrument
non-fires.** Each recorded exactly one `tool_use`, the `Agent` dispatch itself
(`"subagent_type": "seam-probe-agent"`), then ended at `num_turns: 2` with
`subtype: success`. The prompt's Step 2 was simply never executed, so nothing was echoed
through `Bash` and the deterministic instrument had nothing to read. Two independent
checks confirm no refusal occurred: the prompt's unknown-subagent-type refusal line
(`seam-probe-agent dispatch refused: unknown subagent_type`) appears in **no** run, and
every one of the nine runs reports `permission_denials_count: 0` with `is_error: false`.
So those runs are **uninformative in either direction** about fact (i). The verdict helper
correctly reports `SEAM_UNPROVEN` for them, because its rule is "dispatched, no marker" —
that is a statement about the measurement, not about the platform.

**Fact (ii) — governance: 4 corroborating self-reports out of the 4 successful runs that
produced one (5 of 5 including the cancelled run), and 0 contrary reports.** Every run
that got as far as the echo reported `SEAM_PROBE_EFFORT=low` while the session itself ran
at `--effort high`. This is the evidence the decision rule asks a human to adjudicate; it
is a model self-report and remains a weak signal by construction.

**No run has ever produced `SEAM_PROVEN`.** That verdict requires a human to re-run
`scripts/agents-seam-probe-verdict.py` with `--adjudicated-governed` after adjudicating
fact (ii), and no such adjudication is recorded. The highest verdict any dispatch reached
is `SEAM_FORWARDED`, whose decision is explicitly **DO NOT SHIP the applied arm**.

### Scope of this record — evidence only, arm unbuilt

This section records **probe evidence only**. The spike-gated applied arm remains
**unbuilt**: no workflow step composes a resolved per-agent effort into a process-start
agent-definition, no applier→recorder sidecar exists, `resolve-review-overrides.py` still
lists `agent-definition` in its `EFFORT_APPLICATION_POINTS` vocabulary while emitting only
`session-fallback` and `session-inheritance` (its own comment records why: the other two
values belong to a pre-launch component, never this in-session resolver), and the review
skill's statement that per-agent effort is not deliverable per-agent is still accurate. A later reader must not read this recorded evidence as the arm having shipped —
the two are independent, and only the first has happened.

Consequently `docs/review-agent-overrides.md` is unchanged and remains correct: the probe
is still "not yet dispatched to a `SEAM_PROVEN` verdict", and every tier still records
honest fallback.

### Provenance and how to re-check

The nine runs executed the probe at commit `93e5cd13`. The only change to
`.github/workflows/agents-seam-probe.yml` between that commit and the current default
branch is the issue #1002/#1003 rename (the `plugins:` entry and the `Write` grant's state
directory). The measurement mechanism — the `--agents` agent-definition with
`"effort":"low"`, the session's `--effort high`, the model pin, the marker strings, and
the verdict step — is byte-identical, so this evidence still describes the probe as it
stands today.

To re-check a row while the logs survive, read the run's **Compute seam-probe verdict**
step: it prints the verdict table, the `forwarded(marker)=` evidence string, and the raw
`tool_use` entries the verdict was computed from.

> [!NOTE]
> The issue #669 workpad comment recorded a conflicting claim — 8 dispatches, "fact i
> forwarding 8/8", and an adjudicated `SEAM_PROVEN`. Re-reading the run logs does not
> support it: fact (i) was recorded in 4 of 8 successful runs, and no run reached
> `SEAM_PROVEN`. This section, derived from the logs, supersedes that claim.
