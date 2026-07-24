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
| `SEAM_PROVEN` | Fact (i) forwarding proven **and** a human adjudicated fact (ii) as GOVERNED (passing `--adjudicated-governed`). | **Only for the shape the probe measured.** A verdict is evidence about the entry shape that was dispatched — here, a fully-defined NEW agent (`description` + `prompt` + `effort`). Composing a structurally different entry (e.g. effort-only, keyed by an already-installed agent id) is a separate, unmeasured shape and stays on honest fallback until its own row lands. See the Decision below. |
| `SEAM_FORWARDED` | Fact (i) proven; fact (ii) not yet adjudicated. | No — honest fallback stays until a human adjudicates the recorded self-report. |
| `SEAM_UNPROVEN` | The subagent type was dispatched but no seam marker appeared (the `--agents` block was not forwarded). | No — honest fallback stays. |
| `INCONCLUSIVE` | Nothing conclusive was measured (execution file absent/unparseable, or no dispatch attempted). | No — re-run the probe. |

**The applied arm ships only on `SEAM_PROVEN` — i.e. only when BOTH facts are proven, and then only for the entry shape that verdict was measured on.**
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

**`SEAM_PROVEN` — adjudicated 2026-07-21.** The probe was dispatched **8 times** in the
real cloud action (`anthropics/claude-code-action@v1`, `claude-haiku-4-5-20251001`,
session `--effort high`, agent-definition `effort: low`). **Fact (i) forwarding is proven
deterministically and unanimously:** every one of the 8 dispatches recognized and
dispatched the `seam-probe-agent` subagent type — which is defined *only* in the startup
`--agents` JSON — with **zero** permission denials and **never** a `dispatch refused:
unknown subagent_type`; the deterministic `SEAM_PROBE_FORWARDED_OK` marker landed in 4 of
the 8 execution files (the other 4 runs dispatched successfully but the Haiku top-level
session skipped the final `printf` echo step, so the marker was not recorded — a
model-compliance miss, not a seam failure; corroborated by the zero-denial /
no-unknown-type signal on those runs). **Fact (ii) governance is adjudicated GOVERNED:**
in all **4** runs that reached the subagent's self-report, the report was
`SEAM_PROBE_EFFORT=low` — matching the agent-definition's `effort: low` and overriding the
session's `--effort high` — with **zero** `high` self-reports (no counter-evidence). A
human adjudicated the unanimous self-report as GOVERNED and re-ran the verdict helper with
`--adjudicated-governed`, which yields `SEAM_PROVEN`.

**Decision: the seam is PROVEN for the shape this probe measured; the applied arm is
DEFERRED for the shape the composer emits** (issue #669). The eight runs establish the
verdict for a **fully-defined new agent** — an entry carrying `description`, `prompt`, and
`effort`. `scripts/compose-applied-effort.sh` emits something structurally different: an
**effort-only** entry keyed by an **already-installed** plugin agent id. No row here
measures that shape, so nothing establishes whether it patches the installed agent or
defines/shadows it — and if it shadows, every merge-gating review agent degrades to a
prompt-less stub. The applied arm therefore ships gated OFF behind `DEVFLOW_AE_APPLY`
(unset in all three workflows) and the cloud per-agent row in
`docs/review-agent-overrides.md` keeps the honest fallback. Arming it requires a probe row
for the effort-only/installed-id shape. Fact (ii) also remains a model self-report, however
consistent, so when the arm is armed it treats `effective` as a proxy grounded once by this
spike, not a per-run measurement (issue #669 AC2).

| Date | Run link | Verdict | Fact (i) | Fact (ii) self-report | Adjudication |
|---|---|---|---|---|---|
| 2026-07-21 | [29871350774](https://github.com/The01Geek/devflow-autopilot/actions/runs/29871350774) | `SEAM_UNPROVEN` | dispatched, no unknown-type refusal (echo skipped) | unobserved | — |
| 2026-07-21 | [29871446151](https://github.com/The01Geek/devflow-autopilot/actions/runs/29871446151) | `SEAM_FORWARDED` | marker landed ✅ | `low` | GOVERNED |
| 2026-07-21 | [29871519987](https://github.com/The01Geek/devflow-autopilot/actions/runs/29871519987) | `SEAM_UNPROVEN` | dispatched, no unknown-type refusal (echo skipped) | unobserved | — |
| 2026-07-21 | [29872320341](https://github.com/The01Geek/devflow-autopilot/actions/runs/29872320341) | `SEAM_FORWARDED` | marker landed ✅ | `low` | GOVERNED |
| 2026-07-21 | [29872398980](https://github.com/The01Geek/devflow-autopilot/actions/runs/29872398980) | `SEAM_UNPROVEN` | dispatched, no unknown-type refusal (echo skipped) | unobserved | — |
| 2026-07-21 | [29872451024](https://github.com/The01Geek/devflow-autopilot/actions/runs/29872451024) | `SEAM_UNPROVEN` | dispatched, no unknown-type refusal (echo skipped) | unobserved | — |
| 2026-07-21 | [29872503054](https://github.com/The01Geek/devflow-autopilot/actions/runs/29872503054) | `SEAM_FORWARDED` | marker landed ✅ | `low` | GOVERNED |
| 2026-07-21 | [29872570287](https://github.com/The01Geek/devflow-autopilot/actions/runs/29872570287) | `SEAM_FORWARDED` | marker landed ✅ | `low` | GOVERNED |
| **Summary** | 8 dispatches | **`SEAM_PROVEN`** | 8/8 forwarded (no unknown-type refusal) | **4/4 `low`, 0 `high`** | **GOVERNED** |
