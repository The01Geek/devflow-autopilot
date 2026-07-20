# Review-and-Fix split — prompt budget (issue #530)

This table records the prompt-surface budget of `/devflow:review-and-fix` before and after the
issue #530 split of its monolithic `SKILL.md` into a thin root + step references under
`skills/review-and-fix/references/`. It is the checked-in artifact for the #530 word-budget
acceptance criteria; the live regression guard is the `#530 budget` block in `lib/test/run.sh`
(root ≤ 3,500 words; root + live extension ≤ 5,893 words; root + extension + max active step
≤ 17,155 words).

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
> the peak step — see the justified-growth warning below. The initial-load and max-step ceilings
> were raised again (5,690 → 5,824 → 5,865; 17,000 → 17,086 → 17,127) by issue #618, which added the mandated
> "Review-bundle ceiling self-apply" authorization section to the extension — the audited growth
> decision is `docs/cutovers/issue-618-self-apply-authorization.md`. Issue #609 then raised them
> once more (5,865 → 5,877; 17,127 → 17,139): its `dispatched_effort` effort-observability schema
> key, added to the root's record-shape example and to `fixing.md`'s item-7 record shape — the
> merged tree (also carrying PR #625's root trim) measures root 3,226 + extension 2,646 = 5,872
> (initial load) and root + extension + `shadow-review.md` 11,262 = 17,134 (peak step) — the
> audited growth decision is `docs/cutovers/issue-609-agent-effort-observability.md`.

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
| **BEFORE** — always-loaded | monolith + live extension | 1,341 | 38,847 | 268,781 | 50,501 |
| live extension | `.devflow/prompt-extensions/review-and-fix.md` | 207 | 2,646 | 17,853 | 3,440 |
| **AFTER** — plugin root | `skills/review-and-fix/SKILL.md` (thin) | 332 | **3,226** | 26,023 | 4,194 |
| **AFTER** — actual initial load | root + live extension | 539 | **5,881** | 43,924 | 7,642 |
| **AFTER** — bundle | root + all `references/*.md` | 1,318 | 41,090 | 289,541 | 53,417 |
| **AFTER** — normal cumulative path | root + extension + Σ references | — | 43,745 | — | 56,869 |
| **AFTER** — maximum active step | root + extension + `shadow-review.md` | — | **17,143** | — | 22,286 |
| reference: `shadow-review.md` | Step 2.6 | 235 | 11,262 | 79,276 | 14,641 |
| reference: `fixing.md` | Step 3 | 156 | 9,155 | 62,660 | 11,902 |
| reference: `loop-exit.md` | Loop Exit | 273 | 6,587 | 45,177 | 8,563 |
| reference: `loop-control.md` | workpad + field semantics + Main Loop + Steps 0.5–2 | 190 | 5,332 | 37,844 | 6,932 |
| reference: `pre-fix-gates.md` | Step 2.5 + parked-class sweep | 51 | 2,220 | 16,231 | 2,886 |
| reference: `fix-delta-gate.md` | Step 3.5 | 29 | 1,482 | 10,304 | 1,927 |
| reference: `error-handling.md` | When NOT to use + Error Handling + Common Mistakes | 28 | 1,059 | 6,946 | 1,377 |
| reference: `convergence.md` | Step 4.5 | 24 | 767 | 5,080 | 997 |

## Budget ceilings (all met)

| Ceiling | Value | Measured | Result |
| --- | --- | ---: | :--: |
| Plugin root ≤ 3,500 words | 3,500 | 3,226 | ✅ |
| Root + live extension (initial load) ≤ 5,887 words | 5,887 | 5,881 | ✅ |
| Root + extension + max active step ≤ 17,149 words | 17,149 | 17,143 | ✅ |

## Net mandatory-prompt reduction, and the named justified-growth warning

- **Mandatory (always-loaded) prompt: net reduction of 32,975 words** — from 38,847 (monolith +
  extension, *all* of it loaded on every invocation) to 5,872 (thin root + extension). This is the
  reduction the split exists to deliver: everything else now loads on demand, one step reference
  at a time.

- **⚠️ `review-and-fix-split-cumulative-growth` (named justified-growth warning): +4,889 words.**
  The *normal cumulative path* (root + extension + every reference a full run loads in sequence)
  is 43,745 words vs. 38,847 before — a net **growth of +4,889 words** (+12.6%). Three things drive
  it: the routing text the split itself adds (the *Step routing* table, the *Reference-loading
  contract* — entry-gate, canonical-boundary rule, per-reference failure map, always-resident
  re-read rule — the condensed terminal verdict→chat mapping, the durable-operand schema fields,
  and the per-reference `# Reference:` headers / `<!-- END … -->` markers), and the park-calibration
  evidence gate merged in from `main` (issue #557 — the `parking_evidence`/`park_calibration` schema
  fields and the below-verdict-threshold evidence-classification prose in `shadow-review.md`, the
  bulk of the increase), plus the issue #609 `dispatched_effort` effort-observability schema key and its capture/write semantics. It is **justified**: the split trades this cumulative increase for a
  32,975-word reduction in the *mandatory* prompt, on-demand sequential loading (only one step
  reference resident at a time — peak 17,143 words, not 43,745), and fail-closed reference handling.
  Cumulative token spend on a full run is not the metric the split optimizes; peak-context and
  per-step focus are.
