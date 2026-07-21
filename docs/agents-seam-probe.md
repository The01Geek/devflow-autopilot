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

**NOT YET RUN — pending dispatch.** As of issue #610, the probe workflow and its
deterministic verdict helper are authored, but the probe has not been dispatched in the
real cloud action and no `SEAM_PROVEN` evidence exists. Therefore the seam is **unproven**,
the cloud per-agent-effort row remains **honest fallback identical to local**, and **no
per-agent effort application code ships** — exactly AC1's "otherwise" branch. When the
probe is dispatched, append the run link and the adjudicated verdict here.

| Date | Run link | Verdict | Fact (i) | Fact (ii) self-report | Adjudication |
|---|---|---|---|---|---|
| _(pending)_ | _(pending)_ | `NOT YET RUN` | — | — | — |
