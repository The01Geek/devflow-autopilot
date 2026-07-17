# Review engine bundle — prompt budget

`/devflow:review`'s engine is a **bundle**: a thin state-owning root (`skills/review/SKILL.md`)
plus gated phase references under `skills/review/phases/`. Issue #529 split it out of a
1,559-line monolith. This page is the checked-in measurement record for that split and the
budget contract later changes are held to.

## How these numbers are measured

- **Words are `wc -w`.** This is load-bearing, not incidental: `wc -w` is the only method that
  reproduces the pre-split baseline of **33,827 words** that issue #529 states, and it disagrees
  with Python's `str.split()` by ~10 words on this bundle. With AC3's headroom in the low double
  digits, the counting method decides the verdict — during the #529 implementation the
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
| Root (`skills/review/SKILL.md`) | 1,559 / 33,390 / 233,903 / 58,476 | 373 / 7,789 / 52,367 / 13,092 |
| Complete bundle | 1,604 / 33,827 / 237,113 / 59,279 | 1,677 / 34,903 / 245,444 / 61,361 |
| Default per-pass unique path | 1,604 / 33,827 / 237,113 / 59,279 | 1,539 / 28,696 / 202,762 / 50,691 |
| Max incremental phase read | 1,559 / 33,390 / 233,903 / 58,476 | 245 / 6,057 / 42,753 / 10,689 |
| Consumer extension (shipped repo copy) | 45 / 437 / 3,210 / 803 | 45 / 438 / 3,239 / 810 |

**Formulas and included paths**

- **Root** — `skills/review/SKILL.md` alone.
- **Complete bundle** — root + shipped extension + all nine references, each once. It **grows**
  against baseline (+1,076 words); see *Justified growth* below.
- **Default per-pass unique path** — root + shipped extension + each source a pass requires when
  **no blocker fast path** and **no stale-prose predicate** holds, each counted **exactly once**:
  the six always/standalone references, *excluding* the three gated ones (6,207 words). This is the
  conservative reading — it counts `phase-4-4-github-post.md`, which a standalone pass loads and a
  `/devflow:review-and-fix` pass does not, so the review-and-fix default path is *smaller* still
  (27,701 words). **This metric makes no retained-context claim**: it counts what a pass must read,
  not what stays resident.
- **Max incremental phase read** — the largest single reference **by words** (`phase-4-verdict.md`,
  6,057). By *bytes* the largest is `phase-3-agents.md` (43,397 B) — the two maxima are different
  files, so the metric names which one it maximizes rather than implying a single "biggest phase".
- **Consumer extension** — reported as its **own additive row**, never summed into the ceilings.
  This table measures the *shipped repo copy*; a live consumer's
  `.devflow/prompt-extensions/review.md` is theirs and varies, so it is additive on top.

## Ceilings (issue #529 AC2 / AC3)

| Contract | Ceiling | Measured | Margin |
|---|---|---|---|
| Root + shipped extension (AC2) | ≤ 8,500 words | **8,227** | 273 |
| Reduction vs the 33,827 baseline (AC2) | ≥ 25,327 words | **25,600** | 273 |
| Default per-pass unique path (AC3) | ≤ 28,700 words | **28,696** | 4 |

AC3's margin is **thin by construction** — the ceiling sits just above what the split can achieve.
Adding words to the root or to any non-gated reference spends that margin directly. Re-measure with
`wc -w` before adding prose to either.

### The AC3 metric is not the shipped default

AC3's ceiling counts a pass with **no stale-prose predicate**. But `devflow_review.stale_prose.enabled`
defaults **true** in the shipped config, so an *ordinary* pass does read `phases/phase-0-6-stale-prose-lint.md`.
The configuration AC3 measures is therefore one nobody runs by default, and the honest figure is worse
than the gated one:

| Path | Gating | Measured | vs the 28,700 ceiling |
|---|---|---|---|
| AC3 default path (no stale-prose predicate) | **gates this repo** | 28,696 | 4 under |
| Shipped-default path (stale-lint gate at its `true` default) | *non-gating — recorded only* | **30,955** | **2,255 OVER** |

AC3 is implemented **as written**: its literal wording governs the gate, and the number above it is the
one the suite asserts. This second row is published so that the gap between the metric's *name* and the
configuration it actually describes is a documented, greppable fact rather than a silent one — a reader
must not come away believing the shipped default sits under the ceiling. It does not. Reconciling the
two is follow-up work, and it has exactly two honest resolutions: widen the ceiling to cover the
stale-lint reference, or shed words from the default path until the shipped default fits.

## Execution-weighted prompt traffic (issue #529 AC5)

Execution-weighted = the mandatory prompt bytes/tokens a pass actually reads, counting **repeated
reads repeatedly**. Baseline is the monolith, which every pass read in full.

**These rows measure the paths that REALLY execute, which are _not_ the AC3 default set.** AC3 measures
a hypothetical configuration; AC5 measures reality, so each row carries the references its own path
actually loads:

- **`standalone_path`** (218,651 B / 54,663 tok) — the AC3 default set **plus**
  `phases/phase-0-6-stale-prose-lint.md`, whose gate defaults **true**, so an ordinary standalone pass
  reads it. Includes `phases/phase-4-4-github-post.md` (a standalone pass posts to GitHub).
- **`raf_path`** (212,164 B / 53,041 tok) — the same, **minus** the standalone-only
  `phase-4-4-github-post.md`, which `/devflow:review-and-fix` skips entirely.
- `phases/phase-0-3-6-blocker-recheck.md` is in **neither**: its predicate needs a prior REJECT driven
  solely by carve-out blockers, so an ordinary pass never loads it — and on a hit it *replaces* Phases
  1–3 rather than adding to them, so it is never a sum term.

| Path | Formula | Before (bytes / ~tokens) | After (bytes / ~tokens) | Delta |
|---|---|---|---|---|
| Standalone review (1 pass) | `standalone_path × 1` | 237,113 / 59,279 | 218,651 / 54,663 | **−18,462 / −4,616** |
| One normal + shadow pass | `raf_path × 2` | 474,226 / 118,558 | 424,328 / 106,082 | **−49,898 / −12,476** |
| Bounded multi-iteration (2 iters + shadow) | `raf_path × (N+1)`, N=2 | 711,339 / 177,837 | 636,492 / 159,123 | **−74,847 / −18,714** |
| Bounded multi-iteration (3 iters + shadow) | `raf_path × (N+1)`, N=3 | 948,452 / 237,116 | 848,656 / 212,164 | **−99,796 / −24,952** |

**Repeated reads are reported explicitly, not amortized.** The multipliers above *are* the repeat
count: a normal-plus-shadow pass reads its path twice (the shadow re-enters the engine at
`/devflow:review-and-fix` Step 2.6), and a bounded N-iteration loop reads it `N+1` times. Nothing
here is discounted for context that may still be resident — consistent with AC3's explicit
"makes no retained-context claim". These are worst-case re-read figures.

Both AC5-named rows — standalone and one normal-plus-shadow pass — **decrease**, so no
justified-growth warning fires for either. The decrease is real but **smaller than first published**:
an earlier revision of this table measured both rows against the AC3 *default* set, omitting the
stale-lint reference the gate loads by default, and reported the standalone row as −34,401. That
overstated the true reduction by the whole stale-lint reference (~16 KB). The rows above are measured
against the sets each path really loads.

`lib/test/run.sh` asserts these two rows **live** — it re-measures the real member sets and the real
`origin/main` baseline on every run, rather than comparing checked-in constants, so a bundle that grew
past its baseline turns the suite's reading of this table red instead of leaving the numbers above
quietly wrong.

## Justified growth

The **complete bundle** grows by **1,068 words / 8,281 bytes** against baseline. That is the
expected cost of the split and is stated rather than hidden: the root gained the bundle-identity
contract, the boundary contract, and the routing table (~960 words), and each reference carries a
start/end boundary marker pair. The growth buys the AC3 reduction — the gated references
(6,207 words: blocker fast path, stale-prose lint, stale-prose adjudication) leave the default path
entirely, so *every* execution-weighted row above falls even though the static total rises.

Per [`docs/workflow-flight-recorder.md`](workflow-flight-recorder.md), justified growth is **a
warning requiring recurring-cost rationale, not an automatic blocker**.
`lib/test/describe-budget-delta.sh <row> <before> <after>` is the reporter: it emits a named
`::warning::devflow budget: justified-growth: <row> grew by <delta> …` when a row grows, a plain
decrease line when it shrinks, and — per CLAUDE.md's *Unknown is not zero* rule — an explicit
"delta unavailable" when a measurement was never established, rather than collapsing an
unmeasured row onto `0` and reading as "no growth". `lib/test/run.sh` drives every arm.
