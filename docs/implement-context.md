# `/prflow:implement` runtime main-thread context: findings + eval

This document is the single source of truth for **what the `/prflow:implement`
skill's prompt text costs at runtime**, and for the behavioral instrument that
measures it. It is the implement-side counterpart of
[`docs/create-issue-context.md`](create-issue-context.md) (issue #767), and follows
that document's practices: it separates static shipped size from runtime context, it
declines to add any size gate, and it stamps every recorded measurement with its
provenance and marks it a past-time snapshot.

The instrument is `scripts/implement-context-eval.py` (stdlib-only Python), a
**maintainer/CI-adjacent instrument, never invoked by the skill's runtime path**
(neither the local nor the cloud tier), by any workflow, or by any test-suite gate —
its only automated caller is its own focused test,
`lib/test/test_implement_context_eval.py`. It adds **no gate, ceiling, or size
threshold** anywhere.

## Static shipped size vs. runtime main-thread context

Two quantities are easy to conflate; they are different, and only the second is what a
long implement run actually pays:

- **Static shipped size** — the on-disk line/byte count of the phase files
  (`skills/implement/phases/*.md`) and `skills/implement/SKILL.md`. It is fixed at
  author time. Issue #1209 opened by observing these files had grown 19% in lines and
  30% in bytes in two weeks — a real signal that something is unmeasured, but *not* the
  cost a run pays, for the two reasons recorded as findings below. The word-budget
  apparatus that once measured static size was retired by issue #765; this document
  does **not** revive it and adds **no** new static word-count or prompt-length gate.
- **Runtime main-thread context** — the live per-turn token weight the *orchestrator*
  (main thread) carries across a run's many turns and phase (re-)entries. It is measured
  per turn as `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
  This is the quantity `scripts/implement-context-eval.py` measures.

## Two findings the obvious "455 KB of prompt" framing gets wrong

These are the two corrections issue #1209 records as **findings, not background**. Each
rests on specific entry-gate text in `skills/implement/SKILL.md`, quoted here.

### Finding 1 — the phase files are loaded one per phase entry, not all together

`skills/implement/SKILL.md` carries a separate entry gate for each of the four phases.
Each reads, verbatim (Phase N, `<name>`):

> **Entry-gate (mandatory, on every entry):** before any Phase N action, `Read`
> `<skill-dir>/phases/phase-N-<name>.md` and follow it exactly …

A run enters one phase at a time and reads that one phase file when it does. It never
holds all four at once. So the highest phase-file cost at any single phase entry is
roughly **94–131 KB** (whichever single phase file that entry loads — the four span ~94 KB to ~131 KB), not the ~455 KB sum of the four —
with the always-loaded `SKILL.md` (~77 KB) resident alongside it. Optimising against
the 455 KB total would be optimising a cost that does not exist.

### Finding 2 — the re-read on every re-entry and after every nested-skill return is the multiplier worth measuring

The same per-phase entry gate continues, verbatim:

> … re-read it each time you (re-)enter this phase, never relying on an earlier read.

and `skills/implement/SKILL.md`'s **Mid-phase re-anchor after a Skill-tool return**
rule adds, verbatim:

> … after **every** Skill-tool return mid-phase — `simplify`, `review-and-fix`,
> `pr-description`, or any other — re-`Read` the current phase file
> `<skill-dir>/phases/phase-N-<name>.md` and resume …

So a run that bounces through Phase 3's fix loop pays for `phase-3-review.md` again on
every pass, and a run that calls out to a nested skill and returns pays for the current
phase file again. **How many times each phase file is re-read across a run — not how big
it is once — is the cost shape worth measuring.** This is precisely the axis the
instrument reports, and the one the create-issue instrument has no equivalent of.

## The behavioral eval

```
python3 scripts/implement-context-eval.py <transcript-dir>
```

A "run" is bounded by `attributionSkill` matching any declared `<ns>:implement` on
`type == "assistant"` records, with `isSidechain` (dispatched-subagent) records
excluded — the phase files are read by the orchestrator on the main thread, so a
subagent's reads and context are deliberately not counted. One session JSONL file with
at least one attributed main-thread turn yields one run; a resume into a separate
session file is reported as its own run (cross-session merging is out of scope).

It commits no transcript contents, embeds no owner-specific identifiers, streams records
rather than buffering a whole session, degrades per malformed record without detonating
(reporting what it skipped), is deterministic (re-running yields byte-identical output),
and never reads a file whose real path escapes the supplied corpus directory.

**Per-run metrics:** turn count; per-turn main-thread context; peak and final context;
`compact_boundary` count; a count of attributed turns that carried no `usage` object
(`usage_missing_turns` — such a turn's residency was never recorded, so it is tallied
rather than folded in as a `0`, and a run whose every turn lacks usage reports its peak
as `unestablished`); and — reported **separately from the peak, because they are
different quantities** — a per-phase-file read count for each of the four phase files,
plus their per-run total. A phase-file read is a `Read` tool_use whose
`input.file_path` basename is one of the four phase file names; the basename is matched
(not a full path) because the skill anchors the read at
`<skill-dir>/phases/phase-N-<name>.md`, which resolves to a local `skills/implement/…`
path on the interactive tier and a vendored `.prflow/vendor/prflow/skills/implement/…`
path on the cloud tier.

**Aggregate summary:** run count; corpus total of usage-missing turns; median and max
peak context (over the runs with a measured peak — a usage-less run is counted in
`run_count` but excluded from the peak population, never averaged in as a `0`); count of
runs exceeding 200K and 400K; and per phase, the median, max, and corpus total read
count, plus the median and max per-run total phase reads. Every run-derived field reads
`unestablished` (never `0`) on an empty run population; `run_count` is the one field
whose `0` is a measurement.

## Explicit non-goal: splitting the phase files by tier

A tier-conditional split of each phase file into a "cloud" version and a "local" version
is a **declared non-goal** of issue #1209, recorded here with its three reasons so it is
not re-proposed:

1. **The two existing load-on-demand systems fail in opposite directions by design.**
   The review engine's phase bundle fails **closed** (an unreadable reference stops the
   run); the create-issue skill deliberately degrades **open** (issue #614 — a failed
   read leaves a breadcrumb and the run continues, because nothing may block issue
   creation). Adding a tier dimension on top of either creates a new way to halt a
   working run, or a new way to silently skip a phase.
2. **A wrong-tier read cannot fail closed.** Detecting the current tier from inside
   prompt text is unreliable, and the failure is undetectable: reading the cloud file
   while local *succeeds*, and reading the local file while cloud *succeeds*. Both reads
   succeed, so there is no error for a gate to catch — and a gate can only fail closed on
   a read that fails.
3. **It doubles the surface two other things must keep consistent** — `install.sh` and
   the vendor slice would each have to track both tier variants of every phase file.

If a future measurement shows a split is worth it, that is a separate issue with
evidence behind it.

## Baselines

### Fixture-derived companion figure (CI-reconcilable — verified live, NOT a snapshot)

The committed synthetic corpus under `lib/test/fixtures/implement-eval/corpus/` is a
CI-reconcilable check, not a real-run snapshot. `lib/test/test_implement_context_eval.py`
re-derives every expected figure directly from the fixtures rather than hard-coding it,
so changing a fixture updates the assertion. Reproduce it with:

```
python3 scripts/implement-context-eval.py lib/test/fixtures/implement-eval/corpus --format json
```

These are synthetic transcripts chosen to exercise the parser (main-thread filtering,
the sidechain exclusion, phase-file basename matching including a vendored path, a
run over 200K, and a phase-3 re-entry); they are **not** a measurement of any real
`/prflow:implement` run.

### Real corpus snapshot (maintainer measurement obligation — UNFILLED)

No real-corpus snapshot has been captured yet. When a maintainer captures one, record it
here stamped with its provenance — the generating revision, the capture date, and the
corpus size (run count) — and mark it clearly as a **past-time snapshot**, not a live
figure, exactly as `docs/create-issue-context.md`'s "Corpus-derived headline snapshot"
section does. Re-derive any figure with the command above rather than trusting a copied
number; a figure a reader treats as current rots the moment the measured thing changes.
