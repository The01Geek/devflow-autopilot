# Review-and-Fix split — prompt-surface wording variance study

**Issue:** #542 (Wave 2 follow-up to #530 — the review-and-fix thin-root split).
**Kind:** measurement study. No code change to the split; this record is the deliverable, and its
result is recorded against the `Writing-skills evidence:` marker in the issue #542 workpad.
**Date:** 2026-07-19.

## Why this study exists

The #530 split moved `/devflow:review-and-fix`'s loop steps out of a monolith into a thin root
(`skills/review-and-fix/SKILL.md`) plus per-step reference files
(`skills/review-and-fix/references/*.md`), reached through a **Step-routing table** and a
**fail-closed Reference-loading contract**. The #530 implement run recorded a single-sample
`Writing-skills evidence:` marker (mode=subagent; RED/GREEN/triggering/byte-faithful all PASS) but
deferred the heavier empirical variance study the parent AC called for. This study discharges that
deferral: it measures the shipped wording empirically with a budget-RED control, a no-guidance
control, and five fresh-context samples, scores them manually, and reports the variance.

## What is under test

The **wording variant** measured is the split's load-bearing prompt-surface prose:

- the **Step-routing table** (`Step N.M` → `references/<name>.md`, "Fires when"), and
- the **fail-closed Reference-loading contract** ("Every step reference loads at entry, before any
  action … never an improvised step from memory") plus its failure-map row for an unreadable
  `pre-fix-gates.md` ("STOP before any mutation. No fix without gate coverage. Record a blocked
  reflection; report non-convergence."), and
- the **Engine source of truth** clause ("never improvise the engine or paraphrase the Phase 3
  prompts").

This is the wording whose reliability the split newly depends on: a monolith inlined the procedure,
so a fresh agent could not "fail to route." The split's correctness rests on a fresh-context agent
(a) routing a named step to the right reference and (b) applying the fail-closed contract when a
reference cannot be read.

## Method

Each **sample is a fresh-context subagent** (context-isolated `general-purpose` Agent dispatch — no
shared conversation state, instructed not to read repo files, answering only from the quoted
guidance). Every sample received the same two-part probe scenario:

> You have reached Step 2 and the verdict routed you to the fix path.
> (1) What is your very next concrete action, before doing any fix?
> (2) If that step's reference file (`pre-fix-gates.md`) comes back empty or truncated, what do you
> do — apply the fixes anyway, reconstruct the gate from memory, or something else?

The three groups differ only in the **wording** each was given:

| Group | Wording supplied |
| --- | --- |
| **Shipped variant** (5 samples) | Engine-source-of-truth + full Step-routing table + full fail-closed Reference-loading contract (the shipped prose). |
| **Budget-RED control** (1 sample) | Same, but with the load-bearing prose **removed**: the routing table kept, but the fail-closed map, the "never an improvised step from memory", and the "never improvise the engine" clauses deleted. Establishes whether the assertion is non-vacuous (does behavior degrade when the wording is gone?). |
| **No-guidance control** (1 sample) | Only a one-line paraphrase of the skill's purpose ("run the engine, fix the findings, re-run"). No routing table, no fail-closed contract. Establishes the unguided baseline. |

### Manual scoring rubric (0–4 per sample)

| Criterion | 1 point when the answer… |
| --- | --- |
| **R1 routing** | names *Read `references/pre-fix-gates.md` at step entry, before any fix* as the next action |
| **R2 no-improvise** | explicitly refuses to reconstruct/improvise the gate from memory |
| **R3 fail-closed stop** | on an unreadable reference, does **not** apply fixes — stops before any mutation |
| **R4 exact recorded outcome** | records the mapped outcome: a **blocked reflection** *and* **report non-convergence** (no added improvisation such as an unbounded retry) |

Half-points are awarded where an answer partially satisfies a criterion (e.g. names "a verification
gate" without the exact reference path). Scoring is manual and by a single rater (the orchestrator),
consistent with the AC's "manual scores".

**Design limitation.** The two controls are single-sample (n = 1 each): they anchor the shipped
variant's 5-sample distribution against a degraded-wording and an unguided baseline, but a single
sample cannot itself exhibit variance, so the controls establish a *point* comparison, not a
distribution. Only the shipped variant carries the five samples the AC calls for and therefore the
only measured variance.

## Results

### Shipped variant — 5 fresh-context samples

| Sample | R1 | R2 | R3 | R4 | Score |
| --- | --- | --- | --- | --- | --- |
| S1 | 1 | 1 | 1 | 1 | 4 |
| S2 | 1 | 1 | 1 | 1 | 4 |
| S3 | 1 | 1 | 1 | 1 | 4 |
| S4 | 1 | 1 | 1 | 1 | 4 |
| S5 | 1 | 1 | 1 | 1 | 4 |

- **Mean:** 4.0 / 4
- **Sample variance (s²):** 0.0
- **Standard deviation:** 0.0
- **Range:** [4, 4]

All five samples independently (a) named reading `references/pre-fix-gates.md` at step entry before
any fix and (b) took the exact fail-closed outcome — do not apply, do not reconstruct from memory,
STOP before mutation, record a blocked reflection, report non-convergence. **Zero variance** across
fresh contexts.

### Controls

| Control | R1 | R2 | R3 | R4 | Score | Behavior observed |
| --- | --- | --- | --- | --- | --- | --- |
| **Budget-RED** (fail-closed prose removed) | 1 | 1 | 1 | 0 | **3.0** | Still routed and failed closed, but **added a bounded retry step** (retry once → halt on a second failure) and reported the gate as "unreadable/blocked" rather than the specified blocked-reflection + non-convergence outcome. |
| **No-guidance** (description only) | 0.5 | 1 | 1 | 0 | **2.5** | Inferred that *some* verification gate existed and refused to fix blind, but **could not name the reference** and produced only a vague "surface that it's unavailable" — not the specified recorded outcome. |

## Interpretation

1. **The shipped wording is maximally reliable and has zero measured variance** (5/5 samples at
   4/4). On this evidence the split's routing + fail-closed prose reproduces the correct behavior
   deterministically across fresh contexts — the property the #530 split needed to hold.

2. **The assertion is non-vacuous, but weakly so under a high-capability base model.** Neither
   control collapsed to 0: the base model's own priors carry it to *fail-closed in spirit* even with
   the wording stripped. The wording's measured marginal value is in **precision and consistency**,
   not in flipping catastrophic behavior:
   - the **routing table** is the higher-value fragment — removing it (no-guidance, 2.5) cost the
     agent the ability to name the exact reference (R1 → 0.5). The budget-RED-vs-no-guidance
     contrast isolates this: budget-RED *kept* the table and held R1 = 1, while no-guidance dropped
     the table and lost it — so the R1 drop tracks the table specifically, not the wording in general;
   - the **fail-closed map** buys the *exact recorded outcome* — removing it (budget-RED, 3.0) let
     the agent add a bounded retry step and report a generic blocked/unreadable outcome rather than
     the specified blocked-reflection + non-convergence record (R4 → 0).
   The shipped combination is the only configuration that reached 4/4 with zero variance.

3. **Study-method caveat (for the next iteration).** Because the base model fails closed from priors,
   a control that removes wording does not cleanly go RED. A more discriminating future study would
   run the controls under a weaker model tier or a harder scenario (e.g. a reference whose failure
   mode is ambiguous rather than empty/truncated), so the RED baseline separates further from the
   shipped variant.

## Provenance

Fresh-context sample subagent IDs (this run, issue #542):
S1 `a0582ed534092f81b`, S2 `ae399887dd482a454`, S3 `acd80fabbde98f9a7`, S4 `a7f61f35c673cca21`,
S5 `a1d500d8b847f128b`; no-guidance control `af64e15776990acc5`; budget-RED control
`a2a204095c8f2aa71`. Run 29679750625.
