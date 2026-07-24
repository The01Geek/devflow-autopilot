# `/devflow:create-issue` runtime main-thread context: determination + eval

This document is the single source of truth (SSOT, per issue #762) for **how the
`/devflow:create-issue` orchestrator spends runtime main-thread context**, and for
the behavioral instrument that measures it. `CLAUDE.md`'s create-issue bullet and
`docs/DEVFLOW_SYSTEM_OVERVIEW.md` §11 carry one-line pointers here, not copies.

## Static shipped size vs. runtime main-thread context

Two quantities are easy to conflate; they are different, and only the second is
what a long create-issue run actually pays:

- **Static shipped size** — the on-disk word/byte count of the skill files
  (`SKILL.md` + the `references/*.md`). It is fixed at author time and equals runtime
  context only for a single, no-repeat, no-compaction pass — which a multi-round
  create-issue run is not. The word-budget apparatus that measured this quantity was
  retired by issue #766; this document does **not** revive it and adds **no** new
  static word-count or prompt-length gate.
- **Runtime main-thread context** — the live per-turn token weight the *orchestrator*
  (main thread) carries across a run's many turns: clarification rounds, revision
  loops, up to three audit rounds, and staged re-writes. It is measured per turn as
  `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`. This is the
  quantity `scripts/create-issue-context-eval.py` measures, and the cost that drives
  the long-run latency and session-cap pressure issue #767 targets.

The distinction mirrors an earlier precedent that separated static size from
execution-weighted traffic; it is restated here directly (as a standalone concept)
rather than by cross-referencing a budget doc #766 removed, and it does not reuse the
"budget" name.

**`attributionSkill` bounds the main thread only.** A run is bounded by
`attributionSkill == "devflow:create-issue"` on `type == "assistant"` records, with
`isSidechain` records excluded. Dispatched subagents (the docs-verify peers, the
fresh-context auditor) are **not** so attributed, so the measured figures are the
orchestrator's own context — they deliberately exclude subagent cost, which isolates
the reducible main-thread quantity but should not be misread as the run's total cost.

## The behavioral eval

`scripts/create-issue-context-eval.py` (stdlib-only Python, mirroring
`scripts/workpad.py`) is a **maintainer/CI-adjacent instrument, never invoked by the
skill's runtime path** (neither the local nor the cloud tier), so it needs **no** new
cloud-workflow tool grant. It takes a transcript-directory path as an argument:

```
python3 scripts/create-issue-context-eval.py <transcript-dir>
```

That command is the measurement command for **every** figure this document reports.
Running it with no corpus present exits non-zero with a diagnostic naming the missing
path — it never emits a silently-empty baseline. It commits no transcript contents,
embeds no owner-specific identifiers, streams records rather than buffering a whole
session, degrades per malformed record without detonating (reporting what it skipped),
is deterministic (re-running yields byte-identical output), and never reads a file
whose real path escapes the supplied corpus directory.

**Per-run metrics:** turn count; per-turn main-thread context; peak and final context;
total output tokens; `compact_boundary` count; and the two redundant-addition metrics
below.

**Aggregate summary (exactly these fields, complete by construction):** median peak
context, max peak context, count of runs exceeding 200K, count of runs exceeding 400K,
median repeated-Read count, median re-emission count.

### The two redundant-addition metrics

- **repeated-Read** — a `Read` tool_use whose `input.file_path` repeats within the run
  returning content **byte-identical to any content already seen for that path** (a
  re-fetch of already-resident bytes). A repeated Read whose content is **new for the
  path** fetches new bytes, is authoritative, and is **not** counted. **Fail closed:**
  when a Read's `tool_result`
  content is absent or truncated for a record, that occurrence is counted as
  authoritative, never folded into the redundant count.
- **re-emission** — a large (≥ 500-char) assistant text block whose exact bytes were
  already produced earlier in the run (as assistant output or a resident tool_result):
  an output restatement of already-produced content.

## Determination: authoritative vs. redundant additions

The transcript of a create-issue run is **append-only and non-compacting** (the corpus
below shows zero `compact_boundary` events in any run), so nothing "shed" is ever
evicted — the reducible quantity is **redundant future additions**, not a duplicate
resident copy. Each appended-content class is classified below.

### Redundant additions (a later re-fetch/re-emission of already-resident content)

| Class | Canonical durable copy that already holds it | Safely removable here? |
| --- | --- | --- |
| **Re-emission (re-quotation) of an already-produced large block** in the orchestrator's own output — an already-produced Step 1 findings block, an already-produced summary | Step 1 findings: the `.devflow/tmp/issue-step1-<slug>.md` artifact; finding-ledger data: the `issue-audit-state-<slug>.json` field reachable via `query-findings` | **Yes** — removed (see below). Its content is already resident from an earlier append; removing the re-quote touches neither compaction recovery nor a mutable file, and needs no new mechanism. |
| **Reference-body re-Read on step re-entry** (a large `references/*.md` re-Read "on every entry into this step") | The reference file on disk | **No — deferred.** It is *compaction insurance*: on a smaller-context consumer model a compaction evicts the body and the re-Read is the recovery. A static instruction cannot tell a compacting run from a non-compacting one, so safe removal needs an in-run compaction-detection signal this issue does not build. Filed as a follow-up. |

### Authoritative (in-thread presence is load-bearing — must NOT be removed)

- The **live draft under construction**.
- The **current turn's user answer** and the active step's **decision inputs** — including the surviving audit findings **quoted verbatim** for the user's Step 3.6 / Step 4 election, and the advisory/invalid records rendered before the approval election.
- A **reference body re-Read as compaction insurance** (see the deferred row above).
- Any **re-Read of a mutated artifact** — the draft file rewritten each revision round, the Step 1 artifact written then re-read by a later step — which fetches **new** bytes and is authoritative, not a redundant re-fetch.

## The reduction (safely-removable class only)

The safely-removable class — **re-emission of an already-produced large block in the
orchestrator's own output** — is eliminated by instruction: the create-issue skill now
directs the orchestrator to **reference already-resident/durable content by pointer
rather than re-quoting it**. The edited sites are:

- `skills/create-issue/SKILL.md` — Step 1's evidence-artifact instruction and Step 3's
  drafting rule: the Step 1 findings stay resident and durably held in
  `.devflow/tmp/issue-step1-<slug>.md`; Step 3 references them by pointer and does not
  re-emit the findings block into its drafting output.
- `skills/create-issue/references/step-3-6-audit.md` — a runtime-context discipline note
  beside the read-back mandate: consult the `query-findings` read-back and the
  `.devflow/tmp/issue-audit-<slug>.md` artifact by pointer; do not re-emit an
  already-produced findings block into the orchestrator's own reasoning output. The
  user-facing surfaces (findings quoted verbatim for the user, rendered adjudication
  records) are explicitly exempt — they are authoritative decision inputs.

No decision-owning mandatory prose is **removed** by this change — the edits *constrain
how* resident content is referenced, adding no new owner of a workflow decision and
removing none — so no `docs/cutovers/` artifact is required (the helper-cutover
convention triggers only when an executable helper becomes the sole tested owner of a
decision, which is not the case here).

### Preservation (code-reading obligation + reproducible check)

The reduction is an instruction-level change to the LLM orchestrator that no
`issue-audit-state.py`-driven suite test can witness (that tool is unchanged by this
issue). Preservation is discharged as follows, and **no audit finding, evidence
provenance, user decision, draft identity, or state-machine authority is removed or
weakened**:

1. **Code-reading obligation (confirmed).** Each removed re-emission's content stays
   resident and reachable from its named durable copy at the point of use:
   - Step 1 findings: `skills/create-issue/SKILL.md` Step 1 states the orchestrator
     writes the reconciled evidence to `.devflow/tmp/issue-step1-<slug>.md` on **both**
     arms before Step 1 returns (the write-on-every-path contract), so Step 3 always has
     the durable copy to reference. Confirmed by reading that Step 1 producer.
   - Finding-ledger data: `scripts/issue-audit-state.py` remains the ledger owner and
     `query-findings` its authoritative read-back (`grep -c query-findings
     scripts/issue-audit-state.py` → 8), unchanged by this issue; the audit reference
     still mandates deciding "against that read-back, never against context recall."
     Confirmed by reading the state owner and the audit reference.
2. **Reproducible check (numbered, tied to the ACs).** A run relying on the durable
   copies reaches the same audit ledger and verdicts:
   - **Check 1 (ledger read-back path unchanged).** `git diff` on
     `scripts/issue-audit-state.py` for this change is empty — the ledger, `query-findings`,
     and every re-gate decision are byte-identical; the reduction touched only prose in
     `SKILL.md` / `step-3-6-audit.md`. So the audit ledger a run reaches is unchanged.
   - **Check 2 (durable copies still written/queried).** The Step 1 artifact write and
     the `query-findings` read-back sites are unchanged by this change (the edits add
     pointer language beside them, never remove them), so the content the removed
     re-quote used to carry is still produced and still reachable.
   - **Check 3 (transcript-level reduction is detectable).** The eval's committed
     synthetic before/after fixture pair
     (`lib/test/fixtures/create-issue-eval/{before,after}`) reports a strictly lower
     resident total and re-emission count on the after-fixture — demonstrating the eval
     *detects* a modeled reduction (a unit property that passes by construction). It is
     **not** claimed as proof that the shipped skill edit reduces real runs.

## Baselines

### Corpus-derived headline snapshot (documented past-time snapshot — NOT live)

The corpus that produced these figures lives only on the maintainer's machine, so
**no CI check can re-derive them**. They are a documented past-time snapshot, stamped
with provenance, and are **never** presented as a live-generated figure. No
partition/exempt-registry guard is built for this figure (the `#656` `rb-figure-partition.py`
apparatus was removed by #766); the snapshot's integrity rests on its stamped provenance.

| Field | Value |
| --- | --- |
| Generating instrument | `scripts/create-issue-context-eval.py` (drafting-time analyzer of record) |
| Generating revision | `06eecc51975233911594656843ec0e50ac8b4822` (issue #767 branch base) |
| Capture date | 2026-07-24 |
| Corpus size | 451 sessions (342 mention create-issue); **157** bounded create-issue runs |
| Median peak main-thread context | **121K** tokens |
| Max peak main-thread context | **924K** tokens |
| Runs exceeding 200K | **30** of 157 |
| Runs exceeding 400K | **9** of 157 |
| `compact_boundary` events (any run) | **0** |

### Fixture-derived companion figure (CI-reconcilable — verified live)

Distinct from the snapshot above, a figure CI *can* re-derive from the committed
synthetic transcripts in `lib/test/fixtures/create-issue-eval/corpus/` is asserted
**live** by the eval's own test
(`lib/test/test_create_issue_context_eval.py::HappyPathTest`): over that fixture corpus
the aggregate is `median_peak_context = 64000`, `max_peak_context = 250000`,
`runs_over_200k = 1`. If the fixtures change, the test re-derives and the assertion
tracks them — it is never hand-transcribed.

### Real before/after reduction (maintainer measurement obligation — NOT a CI gate)

The **actual** guard against a no-op reduction is a maintainer **before/after corpus
measurement**: a create-issue run captured **before** the skill edit and one **after**,
each a documented past-time snapshot, with the after-run's redundant-addition metric
(or peak context on a comparable run) strictly lower. The corpus is not present in CI,
so this is a recorded maintainer measurement obligation, not a CI gate: **a skill edit
whose real before/after shows no decrease is reverted or deferred, never shipped as a
reduction.** The synthetic fixture is not this guard — it only proves the eval detects
a modeled reduction.

> Maintainer before/after record (to be filled at measurement time):
> - before: run `<id>`, captured `<date>`, peak `<N>`, re-emissions `<M>`
> - after:  run `<id>`, captured `<date>`, peak `<N'>`, re-emissions `<M'>`  (must be strictly lower)

## Explicitly out of scope / deferred (follow-ups)

- **The mechanical "escaped-information" number is not required and not delivered.** The
  corpus cannot deliver it (zero compactions means no post-compaction loss to detect,
  and re-derivation detection needs semantic diffing). Preservation is expressed as the
  code-reading obligation above. LLM-assisted semantic-loss detection over transcripts
  is recorded as an explicit follow-up.
- **The reference-body re-Read on step re-entry is not removed here** — it is compaction
  insurance whose safe removal would need a reliable in-run compaction-detection signal,
  which is out of scope per the problem statement. Recorded as a follow-up.

Both follow-ups are filed as GitHub issues by the implementing run:

- **#774** — safe removal of the reference-body re-Read needs an in-run compaction-detection signal.
- **#775** — LLM-assisted semantic-loss detection over transcripts (the mechanical escaped-information number is not deliverable from this corpus).
