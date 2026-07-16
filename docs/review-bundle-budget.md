# Review engine bundle — prompt budget

`/devflow:review`'s engine is a **bundle**: a thin state-owning root (`skills/review/SKILL.md`)
plus gated phase references under `skills/review/phases/`. Issue #529 split it out of a
1,559-line monolith. This page is the checked-in measurement record for that split and the
budget contract later changes are held to.

## How these numbers are measured

- **Words are `wc -w`.** This is load-bearing, not incidental: `wc -w` is the only method that
  reproduces the pre-split baseline of **33,827 words** that issue #529 states, and it disagrees
  with Python's `str.split()` by ~10 words on this bundle. With single-digit headroom against the
  ceilings below, the counting method decides the verdict — during the #529 implementation the
  `str.split()` figure reported a PASS on a path that `wc -w` scored as a 6-word FAIL. Measure with
  `wc -w`.
- **Bytes** are `wc -c`; **lines** are `wc -l`.
- **Approximate tokens** are `ceil(bytes / 4)` — the same heuristic
  [`docs/workflow-flight-recorder.md`](workflow-flight-recorder.md) uses, and explicitly *not*
  an API-reported count.
- **Baseline ("before")** is `origin/main` at the split: `skills/review/SKILL.md` +
  `.devflow/prompt-extensions/review.md`.

## The bundle

| Source | Loaded when |
|---|---|
| `skills/review/SKILL.md` | always — the root |
| `.devflow/prompt-extensions/review.md` | always — the shipped repo extension |
| `phases/phase-0-setup.md` | always |
| `phases/phase-1-checklist.md` | always |
| `phases/phase-2-verification.md` | always |
| `phases/phase-3-agents.md` | always |
| `phases/phase-4-verdict.md` | always |
| `phases/phase-4-4-github-post.md` | standalone + PR mode only (review-and-fix skips 4.4) |
| `phases/phase-0-3-6-blocker-recheck.md` | **gated** — standalone PR mode, blocker fast path |
| `phases/phase-0-6-stale-prose-lint.md` | **gated** — `devflow_review.stale_prose.enabled` |
| `phases/phase-4-1-7-stale-adjudication.md` | **gated** — PR mode, STALE-finding adjudication |

## Static size

| Row | Before — lines / words / bytes / ~tokens | After — lines / words / bytes / ~tokens |
|---|---|---|
| Root (`skills/review/SKILL.md`) | 1,559 / 33,390 / 233,903 / 58,476 | 372 / 7,802 / 52,438 / 13,110 |
| Complete bundle | 1,604 / 33,827 / 237,113 / 59,279 | 1,674 / 34,894 / 245,365 / 61,342 |
| Default per-pass unique path | 1,604 / 33,827 / 237,113 / 59,279 | 1,536 / 28,687 / 202,683 / 50,671 |
| Max incremental phase read | 1,559 / 33,390 / 233,903 / 58,476 | 243 / 6,036 / 42,632 / 10,658 |
| Consumer extension (shipped repo copy) | 45 / 437 / 3,210 / 803 | 45 / 437 / 3,210 / 803 |

**Formulas and included paths**

- **Root** — `skills/review/SKILL.md` alone.
- **Complete bundle** — root + shipped extension + all nine references, each once. It **grows**
  against baseline (+1,067 words); see *Justified growth* below.
- **Default per-pass unique path** — root + shipped extension + each source a pass requires when
  **no blocker fast path** and **no stale-prose predicate** holds, each counted **exactly once**:
  the six always/standalone references, *excluding* the three gated ones (6,207 words). This is the
  conservative reading — it counts `phase-4-4-github-post.md`, which a standalone pass loads and a
  `/devflow:review-and-fix` pass does not, so the review-and-fix default path is *smaller* still
  (27,692 words). **This metric makes no retained-context claim**: it counts what a pass must read,
  not what stays resident.
- **Max incremental phase read** — the largest single reference **by words** (`phase-4-verdict.md`,
  6,036). By *bytes* the largest is `phase-3-agents.md` (43,397 B) — the two maxima are different
  files, so the metric names which one it maximizes rather than implying a single "biggest phase".
- **Consumer extension** — reported as its **own additive row**, never summed into the ceilings.
  This table measures the *shipped repo copy*; a live consumer's
  `.devflow/prompt-extensions/review.md` is theirs and varies, so it is additive on top.

## Ceilings (issue #529 AC2 / AC3)

| Contract | Ceiling | Measured | Margin |
|---|---|---|---|
| Root + shipped extension (AC2) | ≤ 8,500 words | **8,240** | 260 |
| Reduction vs the 33,827 baseline (AC2) | ≥ 25,327 words | **25,587** | 260 |
| Default per-pass unique path (AC3) | ≤ 28,700 words | **28,687** | 13 |

AC3's margin is **thin by construction** — the ceiling sits just above what the split can achieve.
Adding words to the root or to any non-gated reference spends that margin directly. Re-measure with
`wc -w` before adding prose to either.

## Execution-weighted prompt traffic (issue #529 AC5)

Execution-weighted = the mandatory prompt bytes/tokens a pass actually reads, counting **repeated
reads repeatedly**. Baseline is the monolith, which every pass read in full.

| Path | Formula | Before (bytes / ~tokens) | After (bytes / ~tokens) | Delta |
|---|---|---|---|---|
| Standalone review (1 pass) | `default_path × 1` | 237,113 / 59,279 | 202,683 / 50,671 | **−34,430 / −8,608** |
| One normal + shadow pass | `default_path × 2` | 474,226 / 118,558 | 405,366 / 101,342 | **−68,860 / −17,216** |
| Bounded multi-iteration (2 iters + shadow) | `default_path × (N+1)`, N=2 | 711,339 / 177,837 | 608,049 / 152,013 | **−103,290 / −25,824** |
| Bounded multi-iteration (3 iters + shadow) | `default_path × (N+1)`, N=3 | 948,452 / 237,116 | 810,732 / 202,684 | **−137,720 / −34,432** |

**Repeated reads are reported explicitly, not amortized.** The multipliers above *are* the repeat
count: a normal-plus-shadow pass reads the default path twice (the shadow re-enters the engine at
`/devflow:review-and-fix` Step 2.6), and a bounded N-iteration loop reads it `N+1` times. Nothing
here is discounted for context that may still be resident — consistent with AC3's explicit
"makes no retained-context claim". These are worst-case re-read figures.

Both AC5-named rows — standalone and one normal-plus-shadow pass — **decrease**.

## Justified growth

The **complete bundle** grows by **1,067 words / 8,252 bytes** against baseline. That is the
expected cost of the split and is stated rather than hidden: the root gained the bundle-identity
contract, the boundary contract, and the routing table (~960 words), and each reference carries a
start/end boundary marker pair. The growth buys the AC3 reduction — the gated references
(6,207 words: blocker fast path, stale-prose lint, stale-prose adjudication) leave the default path
entirely, so *every* execution-weighted row above falls even though the static total rises.

Per [`docs/workflow-flight-recorder.md`](workflow-flight-recorder.md), justified growth is **a
warning requiring recurring-cost rationale, not an automatic blocker**.
`scripts/describe-budget-delta.sh <row> <before> <after>` is the reporter: it emits a named
`::warning::devflow budget: justified-growth: <row> grew by <delta> …` when a row grows, a plain
decrease line when it shrinks, and — per CLAUDE.md's *Unknown is not zero* rule — an explicit
"delta unavailable" when a measurement was never established, rather than collapsing an
unmeasured row onto `0` and reading as "no growth". `lib/test/run.sh` drives every arm.
