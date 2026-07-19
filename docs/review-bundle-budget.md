# Review engine bundle — prompt budget

`/devflow:review`'s engine is a **bundle**: a thin state-owning root (`skills/review/SKILL.md`)
plus gated phase references under `skills/review/phases/`. Issue #529 split it out of a
1,559-line monolith. This page is the checked-in measurement record for that split and the
budget contract later changes are held to.

## How these numbers are measured

- **Words are counted by `python3`** — `len(text.split())` over the raw concatenation of the member
  files (`lib/test/run.sh`'s `_rb_words`) — and **never by `wc -w`**. This is not a style
  preference: `wc -w` has no single answer on this bundle. GNU and BSD `wc` disagree, and no locale
  reconciles them, because they disagree in *two different directions*:
  - **Under `LC_ALL=C`**, GNU `wc` counts a word as a run of *printable* characters, and in the C
    locale a byte ≥ `0x80` is not printable — so a token made entirely of non-ASCII (every spaced
    ` — `, ` → `, ` ⇒ ` in this prose) contains no printable byte and GNU **does not count it at
    all**, while BSD counts it as a word. On the default path that is **595 words** silently
    dropped (28,688 BSD vs 28,093 GNU) — a 2% undercount, observed on CI, not theorised.
  - **Under a UTF-8 locale**, BSD `wc` treats the `≠` (U+2260) in the root's `rc≠0` prose as a word
    separator and scores `rc≠0` as **two** words; GNU does not. Worth +12 words.

  So `wc -w` measures the bundle *plus the host*. Every figure on this page before 2026-07-17 was a
  macOS/BSD reading that reproduced at one desk and nowhere else: CI counted the same **bytes** (its
  byte rows passed throughout) but a different number of words, and the AC4 reconciliation went red
  against a record that was right about the bundle and wrong about the host. `python3` is one
  deterministic implementation everywhere, and — unlike `wc` — it is a preflight-guaranteed
  prerequisite. It counts whitespace-delimited tokens: the natural reading, and the one BSD `wc` in
  the C locale agrees with, which is why switching to it left every published figure unchanged.
- **Bytes** are `wc -c`; **lines** are `wc -l`.
- **Approximate tokens** are `ceil(bytes / 4)` — the same heuristic
  [`docs/workflow-flight-recorder.md`](workflow-flight-recorder.md) uses, and explicitly *not*
  an API-reported count. A **multiplied** row (a path read N times) rounds *per pass* and then
  multiplies — `ceil(bytes/4) × N`, not `ceil(bytes × N / 4)` — because the repeat is N separate
  reads, each paying its own rounding. The two conventions differ by a token or three on the
  multiplied rows; on an explicitly approximate heuristic that is noise, but the rows are
  reproducible only against the stated convention.
- **Baseline ("before")** is `origin/main` at the split — rev `4e2ae406`: `skills/review/SKILL.md` +
  `.devflow/prompt-extensions/review.md`, together 237,113 B. Issue #529 states this baseline as
  **33,827 words**; that is the same bytes read by BSD `wc` in a UTF-8 locale (the `≠` artifact above).
  Re-measured under the pinned method it is **33,815 words**, and that is the figure this page and
  `lib/test/run.sh` use — a reduction whose two operands were counted differently is not a
  measurement. The baseline is frozen: a historical measurement cannot change, so only the *after*
  half is re-measured each run.

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
| `phases/phase-4-1-8-prose-cutover.md` | **gated** — prose-cutover adjudication |

## Static size

| Row | Before — lines / words / bytes / ~tokens | After — lines / words / bytes / ~tokens |
|---|---|---|
| Root (`skills/review/SKILL.md`) | 1,559 / 33,378 / 233,903 / 58,476 | 376 / 7,793 / 52,453 / 13,114 |
| Complete bundle | 1,604 / 33,815 / 237,113 / 59,279 | 1,765 / 36,740 / 258,907 / 64,727 |
| Default per-pass unique path | 1,604 / 33,815 / 237,113 / 59,279 | 1,575 / 30,082 / 213,011 / 53,253 |
| Max incremental phase read | 1,559 / 33,378 / 233,903 / 58,476 | 248 / 6,135 / 43,375 / 10,844 |
| Consumer extension (shipped repo copy) | 45 / 437 / 3,210 / 803 | 45 / 439 / 3,280 / 820 |

**Formulas and included paths**

- **Root** — `skills/review/SKILL.md` alone.
- **Complete bundle** — root + shipped extension + all ten references, each once. It **grows**
  against baseline (+2,925 words); see *Justified growth* below.
- **Default per-pass unique path** — root + shipped extension + each source a pass requires when
  **no blocker fast path** and **no stale-prose predicate** holds, each counted **exactly once**:
  the six always/standalone references, *excluding* the four gated ones (6,698 words). This is the
  conservative reading — it counts `phase-4-4-github-post.md`, which a standalone pass loads and a
  `/devflow:review-and-fix` pass does not, so the review-and-fix default path is *smaller* still
  (29,047 words). **This metric makes no retained-context claim**: it counts what a pass must read,
  not what stays resident.
- **Max incremental phase read** — the largest single reference **by words** (`phase-4-verdict.md`,
  6,135). By *bytes* the largest is `phase-3-agents.md` (43,416 B) — the two maxima are different
  files, so the metric names which one it maximizes rather than implying a single "biggest phase".
- **Consumer extension** — reported as its **own additive row**, never summed into the ceilings.
  This table measures the *shipped repo copy*; a live consumer's
  `.devflow/prompt-extensions/review.md` is theirs and varies, so it is additive on top.

## Ceilings (issue #529 AC2 / AC3)

| Contract | Ceiling | Measured | Margin |
|---|---|---|---|
| Root + shipped extension (AC2) | ≤ 8,500 words | **8,232** | 268 |
| Reduction vs the 33,815 baseline (AC2) | ≥ 25,327 words | **25,583** | 256 |
| Default per-pass unique path (AC3) | ≤ 30,100 words | **30,082** | 18 |

AC3's margin is **thin by construction** — the ceiling sits just above what the split can achieve.
Adding words to the root or to any non-gated reference spends that margin directly. Re-measure with
the `python3` counter above (`lib/test/run.sh`'s `_rb_words`) before adding prose to either — a
`wc -w` reading will disagree with the record on some hosts.

### The AC3 metric is not the shipped default

AC3's ceiling counts a pass with **no stale-prose predicate**. But `devflow_review.stale_prose.enabled`
defaults **true** in the shipped config, so an *ordinary* pass does read `phases/phase-0-6-stale-prose-lint.md`.
The configuration AC3 measures is therefore one nobody runs by default, and the honest figure is worse
than the gated one:

| Path | Gating | Measured | vs the 30,100 ceiling |
|---|---|---|---|
| AC3 default path (no stale-prose predicate) | **gates this repo** | 30,082 | 18 under |
| Shipped-default path (stale-lint gate at its `true` default) | *non-gating — recorded only* | **32,339** | **2,239 OVER** |

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

- **`standalone_path`** (228,900 B / 57,225 tok) — the AC3 default set **plus**
  `phases/phase-0-6-stale-prose-lint.md`, whose gate defaults **true**, so an ordinary standalone pass
  reads it. Includes `phases/phase-4-4-github-post.md` (a standalone pass posts to GitHub).
- **`raf_path`** (222,413 B / 55,604 tok) — the same, **minus** the standalone-only
  `phase-4-4-github-post.md`, which `/devflow:review-and-fix` skips entirely.
- `phases/phase-0-3-6-blocker-recheck.md` is in **neither**: its predicate needs a prior REJECT driven
  solely by carve-out blockers, so an ordinary pass never loads it — and on a hit it *replaces* Phases
  1–3 rather than adding to them, so it is never a sum term.

| Path | Formula | Before (bytes / ~tokens) | After (bytes / ~tokens) | Delta |
|---|---|---|---|---|
| Standalone review (1 pass) | `standalone_path × 1` | 237,113 / 59,279 | 228,900 / 57,225 | **−8,213 / −2,054** |
| One normal + shadow pass | `raf_path × 2` | 474,226 / 118,558 | 444,826 / 111,208 | **−29,400 / −7,350** |
| Bounded multi-iteration (2 iters + shadow) | `raf_path × (N+1)`, N=2 | 711,339 / 177,837 | 666,384 / 166,596 | **−44,955 / −11,241** |
| Bounded multi-iteration (3 iters + shadow) | `raf_path × (N+1)`, N=3 | 948,452 / 237,116 | 889,652 / 222,416 | **−58,800 / −14,700** |

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

`lib/test/run.sh` re-measures the **after** side of these rows from the real member sets on every
run and compares it against a **frozen** pre-split baseline — so a bundle that grew past that
baseline turns the suite red instead of leaving the numbers above quietly wrong. Only the *after*
needs to be live; the baseline is a historical measurement of a commit that no longer moves, and it
is checked in as a constant on purpose. **Do not "restore" a live `origin/main` read here.** That is
what the code used to do, and it was a trap: once this split merges, `origin/main` *is* the split, so
the baseline would collapse from the monolith's bytes to the thin root's, both rows would invert into
a growth warning, and the required CI job would go red on the merge commit and on every pull request
after it — green in the PR that introduced it, red forever after. The suite reconciles that constant
against the figure this page publishes, so the two cannot drift apart.

## Justified growth

The **complete bundle** grows by **2,925 words / 22,079 bytes** against baseline. That is the
expected cost of the split and is stated rather than hidden: the root gained the bundle-identity
contract, the boundary contract, and the routing table (~960 words), and each reference carries a
start/end boundary marker pair. The growth buys the AC3 reduction — the gated references
(6,698 words: blocker fast path, stale-prose lint, stale-prose adjudication, prose cutover) leave the default path
entirely, so *every* execution-weighted row above falls even though the static total rises.

Per [`docs/workflow-flight-recorder.md`](workflow-flight-recorder.md), justified growth is **a
warning requiring recurring-cost rationale, not an automatic blocker**.
`lib/test/describe-budget-delta.sh <row> <before> <after>` is the reporter: it emits a named
`::warning::devflow budget: justified-growth: <row> grew by <delta> …` when a row grows, a plain
decrease line when it shrinks, and — per CLAUDE.md's *Unknown is not zero* rule — an explicit
"delta unavailable" when a measurement was never established, rather than collapsing an
unmeasured row onto `0` and reading as "no growth". `lib/test/run.sh` drives every arm.
