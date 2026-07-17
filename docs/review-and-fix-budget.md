# Review-and-Fix split — prompt budget (issue #530)

This table records the prompt-surface budget of `/devflow:review-and-fix` before and after the
issue #530 split of its monolithic `SKILL.md` into a thin root + step references under
`skills/review-and-fix/references/`. It is the checked-in artifact for the #530 word-budget
acceptance criteria; the live regression guard is the `#530 budget` block in `lib/test/run.sh`
(root ≤ 3,000 words; root + live extension ≤ 5,500 words; root + extension + max active step
≤ 15,000 words).

> **Maintainer note — the root budget is razor-thin.** The root measures **2,994 / 3,000 words**
> (~6 words of headroom). Any non-trivial addition to `skills/review-and-fix/SKILL.md` will trip
> the `#530 budget` guard; externalize new procedure into a reference (or trim) rather than
> growing the root. Re-run the measurement below (always the python3 word counter — see
> Counting method; never a bare `wc -w`)
> and reconcile the numbers in this table and the `+1,207` figure pinned in `lib/test/run.sh`
> whenever the root or a reference changes; the `#530 budget` guard recomputes the cumulative
> sum and the growth arithmetic from the live files, so a stale table cell goes RED at the desk.

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
- **approx tokens = words × 1.3, rounded to the nearest whole number (half up)** (a coarse
  English-prose estimate; stated as a formula, not a measured tokenizer count).
- **BEFORE basis:** the pre-split monolith `SKILL.md` as of the split's base commit on `main`;
  the live-extension addend in the BEFORE always-loaded row is the *current* extension file
  (same addend as the AFTER rows), so the two always-loaded rows isolate the split itself
  rather than the unrelated one-word extension edit made on this branch.
- **live extension** = `.devflow/prompt-extensions/review-and-fix.md` (this repo's own extension;
  a consumer's extension cost is measured separately and added to the plugin-root row — no global
  consumer-extension ceiling is claimed).
- **actual initial load** = plugin root + live extension (what is *always* loaded at invocation).
- **bundle** = plugin root + every `references/*.md` (the whole shipped skill surface).
- **normal cumulative path** = root + extension + every reference a converging run loads in
  sequence (Σ references; the maximal case — a clean immediate-APPROVE run loads fewer).
- **maximum active step** = root + extension + the single largest step reference
  (`shadow-review.md`), the peak when exactly one step reference is resident at a time (the
  always-resident re-read rule loads each reference on demand — none is held resident).

## Before / after

| Row | Included paths | Lines | Words | Bytes | ≈Tokens |
| --- | --- | ---: | ---: | ---: | ---: |
| **BEFORE** — monolith | `skills/review-and-fix/SKILL.md` (pre-split) | 1,134 | 36,201 | 250,928 | 47,061 |
| **BEFORE** — always-loaded | monolith + live extension | 1,330 | 38,628 | 266,909 | 50,216 |
| live extension | `.devflow/prompt-extensions/review-and-fix.md` | 196 | 2,427 | 15,981 | 3,155 |
| **AFTER** — plugin root | `skills/review-and-fix/SKILL.md` (thin) | 286 | **2,994** | 23,467 | 3,892 |
| **AFTER** — actual initial load | root + live extension | 482 | **5,421** | 39,448 | 7,047 |
| **AFTER** — bundle | root + all `references/*.md` | 1,236 | 37,397 | 259,973 | 48,616 |
| **AFTER** — normal cumulative path | root + extension + Σ references | — | 39,835 | — | 51,786 |
| **AFTER** — maximum active step | root + extension + `shadow-review.md` | — | **14,988** | — | 19,484 |
| reference: `shadow-review.md` | Step 2.6 | 214 | 9,567 | 66,549 | 12,437 |
| reference: `fixing.md` | Step 3 | 154 | 8,323 | 56,188 | 10,820 |
| reference: `loop-exit.md` | Loop Exit | 270 | 6,488 | 44,465 | 8,434 |
| reference: `loop-control.md` | workpad + field semantics + Main Loop + Steps 0.5–2 | 184 | 4,842 | 33,839 | 6,295 |
| reference: `pre-fix-gates.md` | Step 2.5 + parked-class sweep | 49 | 1,996 | 14,341 | 2,595 |
| reference: `fix-delta-gate.md` | Step 3.5 | 27 | 1,376 | 9,312 | 1,789 |
| reference: `error-handling.md` | When NOT to use + Error Handling + Common Mistakes | 28 | 1,055 | 6,880 | 1,372 |
| reference: `convergence.md` | Step 4.5 | 24 | 767 | 5,080 | 997 |

## Budget ceilings (all met)

| Ceiling | Value | Measured | Result |
| --- | --- | ---: | :--: |
| Plugin root ≤ 3,000 words | 3,000 | 2,994 | ✅ |
| Root + live extension (initial load) ≤ 5,500 words | 5,500 | 5,421 | ✅ |
| Root + extension + max active step ≤ 15,000 words | 15,000 | 14,988 | ✅ |

## Net mandatory-prompt reduction, and the named justified-growth warning

- **Mandatory (always-loaded) prompt: net reduction of 33,207 words** — from 38,628 (monolith +
  extension, *all* of it loaded on every invocation) to 5,421 (thin root + extension). This is the
  reduction the split exists to deliver: at least 33,134 words below the measured combined baseline
  (33,207 ≥ 33,134). Everything else now loads on demand, one step reference at a time.

- **⚠️ `review-and-fix-split-cumulative-growth` (named justified-growth warning): +1,207 words.**
  The *normal cumulative path* (root + extension + every reference a full run loads in sequence)
  is 39,835 words vs. 38,628 before — a net **growth of +1,207 words**. This growth is the routing
  text the split adds: the *Step routing* table, the *Reference-loading contract* (entry-gate,
  canonical-boundary rule, per-reference failure map, always-resident re-read rule), the condensed
  terminal verdict→chat mapping, the durable-operand schema fields, and the per-reference
  `# Reference:` headers / `<!-- END … -->` markers. It is **justified**: the split trades this
  small (+3.1%) cumulative increase for a 33,207-word reduction in the *mandatory* prompt, on-demand
  sequential loading (only one step reference resident at a time — peak 14,988 words, not 39,835),
  and fail-closed reference handling. Cumulative token spend on a full run is not the metric the
  split optimizes; peak-context and per-step focus are.
