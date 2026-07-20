# Review-and-Fix split — prompt budget (issue #530)

This table records the prompt-surface budget of `/devflow:review-and-fix` before and after the
issue #530 split of its monolithic `SKILL.md` into a thin root + step references under
`skills/review-and-fix/references/`. It is the checked-in artifact for the #530 word-budget
acceptance criteria; the live regression guard is the `#530 budget` block in `lib/test/run.sh`
(root ≤ 3,500 words; root + both live extensions ≤ 7,374 words; root + both extensions + max
active step ≤ 18,636 words).

> **Maintainer note — the root is the tightest budget.** The root sits below its 3,500-word
> ceiling (see the **AFTER — plugin root** row and the ceilings table below; the `#530 budget`
> guard binds that Measured cell to the live python3 count, so it cannot silently drift). Any
> non-trivial addition to `skills/review-and-fix/SKILL.md` risks tripping the guard; externalize
> new procedure into a reference (or trim) rather than growing the root. Re-run the measurement
> below (always the python3 word counter — see Counting method; never a bare `wc -w`) and
> reconcile this table against the growth-delta figure pinned in `lib/test/run.sh` whenever the
> root or a reference changes; the `#530 budget` guard binds the ceiling constants, the Measured
> cells, the cumulative-path / growth-delta / net-reduction figures, and the max-step reference
> label to live measurements, so a stale one of those goes RED at the desk. The ceilings were
> raised from their split-only values (root 3,000 → 3,500; max active step 15,000 → 17,000) when
> the park-calibration evidence gate (issue #557) merged in from `main`: that feature adds the
> `parking_evidence`/`park_calibration` schema fields to the root and the below-verdict-threshold
> evidence-classification prose to `shadow-review.md`, enlarging both the always-loaded root and
> the peak step — see the justified-growth warning below. Issue #620 then **widened two of the
> measures themselves**, not just their ceilings: the root now loads
> `.devflow/prompt-extensions/receiving-code-review.md` at entry, so the initial-load and
> max-active-step rows became three-term sums (initial load 5,690 → 7,374; max active step
> 17,000 → 18,636). The root ceiling was *not* renegotiated — the scoping prose that call carries
> left it at 3,464 of 3,500, and that remaining 36-word margin is now the tightest budget in this
> table. The audited decision is `docs/cutovers/issue-620-reception-extension-port.md`.

## Counting method & formulas

- **lines / bytes** are `wc -l` / `wc -c` of each file. **words** are ASCII-whitespace-delimited
  byte tokens: `python3 -c 'import sys; print(len(open(sys.argv[1],"rb").read().split()))' <file>`
  — the exact counter the `run.sh` guard uses (python3 is a preflight prerequisite).
  **`wc -w` is deliberately not the arbiter — it disagrees with itself across platforms on this
  corpus in both locales.** BSD `wc` under a UTF-8 locale (macOS default) splits words on some
  multibyte punctuation (`≠` U+2260, present in several references) that glibc does not — that
  skew got this file's original macOS-measured counts rejected by a Linux reviewer re-measuring
  the same HEAD. And under `LC_ALL=C`, GNU `wc` counts only whitespace-runs containing a
  printable ASCII byte, so the standalone em-dash tokens this prose uses heavily count as words
  on macOS/BSD but not on Linux CI (observed on an earlier round of this branch: 39,826 vs 39,053 for identical cumulative bytes).
  `bytes.split()` is byte-identical everywhere; on this corpus it equals BSD `LC_ALL=C wc -w`.
  Totals here can therefore differ by a few words from earlier unpinned measurements quoted in
  issue #530 (its 38,634-word baseline was a BSD-UTF-8 count of the same bytes).
- **approx tokens = words × 1.3, rounded to the nearest whole number (Python `round()`, i.e. round half to even)** (a coarse
  English-prose estimate; stated as a formula, not a measured tokenizer count).
- **BEFORE basis:** the pre-split monolith `SKILL.md` at the split's **pre-#557 fork point** on `main` — commit `a263f9ab` (the last `main` commit before the #557 park-calibration merge `de9d74f0`; the PR's literal merge-base already contains #557, so re-measuring there reads higher — see the maintainer note);
  the live-extension addend in the BEFORE always-loaded row is the *current* extension file
  (same addend as the AFTER rows), so the two always-loaded rows isolate the split itself
  rather than the unrelated one-word extension edit made on this branch.
- **live extension** = `.devflow/prompt-extensions/review-and-fix.md` (this repo's own extension;
  a consumer's extension cost is measured separately and added to the plugin-root row — no global
  consumer-extension ceiling is claimed).
- **receiving extension** = `.devflow/prompt-extensions/receiving-code-review.md`, loaded at skill
  entry since issue #620 so the fix loop applies the same repo reception policy a direct pass
  does. It is therefore part of the *always-loaded* surface and enters the initial-load and
  max-active-step measures — but it is deliberately **excluded from the cumulative-path and
  growth-delta arithmetic below**, whose whole job is to isolate the #530 split against a frozen
  pre-split monolith basis that never loaded this file; folding it in would pollute that
  comparison rather than measure the split.
- **actual initial load** = plugin root + live extension + receiving extension (what is *always*
  loaded at invocation).
- **bundle** = plugin root + every `references/*.md` (the whole shipped skill surface).
- **normal cumulative path** = root + live extension + every reference a converging run loads in
  sequence (Σ references; the maximal case — a clean immediate-APPROVE run loads fewer). The
  receiving extension is excluded, per its definition above.
- **maximum active step** = root + both extensions + the single largest step reference
  (`shadow-review.md`), the peak when exactly one step reference is resident at a time (the
  always-resident re-read rule loads each reference on demand — none is held resident).

## Before / after

| Row | Included paths | Lines | Words | Bytes | ≈Tokens |
| --- | --- | ---: | ---: | ---: | ---: |
| **BEFORE** — monolith | `skills/review-and-fix/SKILL.md` (pre-split) | 1,134 | 36,201 | 250,928 | 47,061 |
| **BEFORE** — always-loaded | monolith + live extension | 1,337 | 38,674 | 267,474 | 50,271 |
| live extension | `.devflow/prompt-extensions/review-and-fix.md` | 203 | 2,473 | 16,546 | 3,210 |
| receiving extension | `.devflow/prompt-extensions/receiving-code-review.md` | 89 | 1,433 | 9,607 | 1,863 |
| **AFTER** — plugin root | `skills/review-and-fix/SKILL.md` (thin) | 336 | **3,464** | 27,459 | 4,503 |
| **AFTER** — actual initial load | root + both live extensions | 628 | **7,370** | 53,612 | 9,581 |
| **AFTER** — bundle | root + all `references/*.md` | 1,318 | 40,775 | 286,479 | 53,008 |
| **AFTER** — normal cumulative path | root + live extension + Σ references | — | 43,248 | — | 56,222 |
| **AFTER** — maximum active step | root + both extensions + `shadow-review.md` | — | **18,632** | — | 24,222 |
| reference: `shadow-review.md` | Step 2.6 | 235 | 11,262 | 79,276 | 14,641 |
| reference: `fixing.md` | Step 3 | 156 | 8,845 | 60,302 | 11,561 |
| reference: `loop-exit.md` | Loop Exit | 273 | 6,594 | 45,216 | 8,576 |
| reference: `loop-control.md` | workpad + field semantics + Main Loop + Steps 0.5–2 | 188 | 5,189 | 36,686 | 6,746 |
| reference: `pre-fix-gates.md` | Step 2.5 + parked-class sweep | 51 | 2,220 | 16,231 | 2,886 |
| reference: `fix-delta-gate.md` | Step 3.5 | 27 | 1,379 | 9,349 | 1,793 |
| reference: `error-handling.md` | When NOT to use + Error Handling + Common Mistakes | 28 | 1,055 | 6,880 | 1,372 |
| reference: `convergence.md` | Step 4.5 | 24 | 767 | 5,080 | 997 |

## Budget ceilings (all met)

| Ceiling | Value | Measured | Result |
| --- | --- | ---: | :--: |
| Plugin root ≤ 3,500 words | 3,500 | 3,464 | ✅ |
| Root + both live extensions (initial load) ≤ 7,374 words | 7,374 | 7,370 | ✅ |
| Root + both extensions + max active step ≤ 18,636 words | 18,636 | 18,632 | ✅ |

## Net mandatory-prompt reduction, and the named justified-growth warning

- **Mandatory (always-loaded) prompt: net reduction of 32,737 words** — from 38,674 (monolith +
  extension, *all* of it loaded on every invocation) to 5,937 (thin root + live extension). This is
  the reduction the split exists to deliver: everything else now loads on demand, one step
  reference at a time. Both sides of this comparison exclude the receiving extension, which the
  pre-split basis never loaded — counting it on one side only would understate the split's
  reduction by 1,433 words. The *actual* always-loaded surface since issue #620 is the 7,370-word
  initial-load row above.

- **⚠️ `review-and-fix-split-cumulative-growth` (named justified-growth warning): +4,574 words.**
  The *normal cumulative path* (root + live extension + every reference a full run loads in
  sequence — the receiving extension excluded, per Counting method) is 43,248 words vs. 38,674
  before — a net **growth of +4,574 words** (+11.8%). Its drivers are
  the routing text the split itself adds (the *Step routing* table, the *Reference-loading
  contract* — entry-gate, canonical-boundary rule, per-reference failure map, always-resident
  re-read rule — the condensed terminal verdict→chat mapping, the durable-operand schema fields,
  and the per-reference `# Reference:` headers / `<!-- END … -->` markers), the park-calibration
  evidence gate merged in from `main` (issue #557 — the `parking_evidence`/`park_calibration` schema
  fields and the below-verdict-threshold evidence-classification prose in `shadow-review.md`, the
  bulk of the increase), and the issue-#620 receiving-extension loader call and its scoping prose
  in the root. It is **justified**: the split trades this cumulative increase for a
  32,737-word reduction in the *mandatory* prompt, on-demand sequential loading (only one step
  reference resident at a time — peak 18,632 words, not 43,248), and fail-closed reference handling.
  Cumulative token spend on a full run is not the metric the split optimizes; peak-context and
  per-step focus are.
