# Review-and-Fix split — prompt budget (issue #530)

This table records the prompt-surface budget of `/devflow:review-and-fix` before and after the
issue #530 split of its monolithic `SKILL.md` into a thin root + step references under
`skills/review-and-fix/references/`. It is the checked-in artifact for the #530 word-budget
acceptance criteria; the live regression guard is the `#530 budget` block in `lib/test/run.sh`
(root ≤ 3,567 words; root + always-loaded extensions ≤ 9,007 words; root + always-loaded
extensions + max active step ≤ 20,346 words).

> **Maintainer note — the root is the budget to watch.** The root sits below its 3,567-word
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
> audited growth decision is `docs/cutovers/issue-609-agent-effort-observability.md`. Issue #620 then widened two of the
> *measures* themselves, not just their ceilings — the root now loads
> `.devflow/prompt-extensions/receiving-code-review.md` at entry (see the ceilings table). The
> root ceiling was renegotiated 3,500 → 3,567 across this issue's work and the `main` merges it absorbed. Audited decision:
> `docs/cutovers/issue-620-reception-extension-port.md`. Issue #640 then moved the supersession
> guard's editor-authority *mechanism* out of the root and into the always-loaded receiving
> extension so a **direct** `/devflow:receiving-code-review` pass inherits it (not only the loop),
> leaving in the root just a loop-tail pointer — the root drops to 3,414 of 3,567. The relocation is
> per-surface neutral, but the extension's self-contained direct-pass framing nets +81 words on the
> always-loaded surface, so the initial-load and max-step ceilings were raised 7,653 → 7,734 and
> 18,915 → 18,996 (each measured + ~4 headroom). Audited decision:
> `docs/cutovers/issue-640-direct-pass-editor-authority.md`.

## Counting method & formulas

- **lines / bytes** are the newline count / byte length of each file, measured with the same
  `python3` reader the guard uses (`wc -l` / `wc -c` agree numerically; the guard avoids them
  because a value deciding an assertion must not route through a non-preflight PATH tool). **words** are ASCII-whitespace-delimited
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
- **always-loaded extensions** = the live extension plus the receiving extension (the set the root
  loads at entry; naming the set here keeps the row labels below free of a member count).
- **actual initial load** = plugin root + always-loaded extensions (what is *always* loaded at
  invocation).
- **bundle** = plugin root + every `references/*.md` (the whole shipped skill surface).
- **normal cumulative path** = root + live extension + every reference a converging run loads in
  sequence (Σ references; the maximal case — a clean immediate-APPROVE run loads fewer). The
  receiving extension is excluded, per its definition above.
- **maximum active step** = root + always-loaded extensions + the single largest step reference
  (`shadow-review.md`), the peak when exactly one step reference is resident at a time (the
  always-resident re-read rule loads each reference on demand — none is held resident).

## Before / after

| Row | Included paths | Lines | Words | Bytes | ≈Tokens |
| --- | --- | ---: | ---: | ---: | ---: |
| **BEFORE** — monolith | `skills/review-and-fix/SKILL.md` (pre-split) | 1,134 | 36,201 | 250,928 | 47,061 |
| **BEFORE** — always-loaded | monolith + live extension | 1,387 | 39,532 | 273,248 | 51,392 |
| live extension | `.devflow/prompt-extensions/review-and-fix.md` | 253 | 3,331 | 22,320 | 4,330 |
| receiving extension | `.devflow/prompt-extensions/receiving-code-review.md` | 139 | 2,258 | 15,128 | 2,935 |
| **AFTER** — plugin root | `skills/review-and-fix/SKILL.md` (thin) | 342 | **3,414** | 27,394 | 4,438 |
| **AFTER** — actual initial load | root + always-loaded extensions | 734 | **9,003** | 64,842 | 11,704 |
| **AFTER** — bundle | root + all `references/*.md` | 1,333 | 42,252 | 298,444 | 54,928 |
| **AFTER** — normal cumulative path | root + live extension + Σ references | — | 45,583 | — | 59,258 |
| **AFTER** — maximum active step | root + always-loaded extensions + `shadow-review.md` | — | **20,342** | — | 26,445 |
| reference: `shadow-review.md` | Step 2.6 | 235 | 11,339 | 79,930 | 14,741 |
| reference: `fixing.md` | Step 3 | 157 | 9,648 | 66,384 | 12,542 |
| reference: `loop-exit.md` | Loop Exit | 276 | 6,693 | 46,065 | 8,701 |
| reference: `loop-control.md` | workpad + field semantics + Main Loop + Steps 0.5–2 | 191 | 5,597 | 39,864 | 7,276 |
| reference: `pre-fix-gates.md` | Step 2.5 + parked-class sweep | 51 | 2,253 | 16,477 | 2,929 |
| reference: `fix-delta-gate.md` | Step 3.5 | 29 | 1,482 | 10,304 | 1,927 |
| reference: `error-handling.md` | When NOT to use + Error Handling + Common Mistakes | 28 | 1,059 | 6,946 | 1,377 |
| reference: `convergence.md` | Step 4.5 | 24 | 767 | 5,080 | 997 |

## Budget ceilings (all met)

| Ceiling | Value | Measured | Result |
| --- | --- | ---: | :--: |
| Plugin root ≤ 3,567 words | 3,567 | 3,414 | ✅ |
| Root + always-loaded extensions (initial load) ≤ 9,007 words | 9,007 | 9,003 | ✅ |
| Root + always-loaded extensions + max active step ≤ 20,346 words | 20,346 | 20,342 | ✅ |

> **Ceiling renegotiation — issue #621.** The `settled-by-disclosure` foreclosure vocabulary added
> AC-mandated prose to `shadow-review.md` (the max-active-step reference), taking the max-active-step
> measure to **19,069** words — past the #640 ceiling of 18,996, which carried only ~4 words of margin.
> The bundle was at capacity, so trimming could not clear it without dropping required content; the
> max-step ceiling was re-measured to **19,073** (measured + the same ~4-word margin the #619/#640
> cutovers use). The initial-load ceiling (7,734) and the plugin-root ceiling (3,567) are untouched —
> this change edited references only, not the root or the always-loaded extensions.

> **Ceiling renegotiation — issue #655.** The generalized regenerate-on-conflict rule is byte-identical
> across the three DevFlow prompt extensions, and two of them (`review-and-fix.md`,
> `receiving-code-review.md`) are on this bundle's always-loaded surface since #620 — so the rule lands
> on the initial load **twice, 476 words each (+952)**. AC7 pins the three copies byte-identical and
> requires the oracle citation, the conflict-path/conflict-sibling match, the class+recipe read, and
> both fail-closed defaults, so it cannot be split or shortened past that operative minimum. Both
> ceilings move +952 over their #621 bases: initial load 7,734 → **8,686** (measured 8,682) and
> max active step 19,073 → **20,025** (measured 20,021), each carrying the same ~4-word margin. The
> audited decision is `docs/cutovers/issue-655-conflict-oracle.md`.

> **Ceiling renegotiation — issue #707.** Inverting the verification default to focused-first and
> parallelizing the final gate rewrote the focused-module section in **both** always-loaded
> extensions (`review-and-fix.md`, `receiving-code-review.md`), and the replacement states more
> than the retired one did: the focused-sufficiency rule, the mid-iteration reservation, the
> non-gated push paired with the gated *claim*, the authoritative-local-signal rationale, and the
> restated `#405` cloud carve-out — each an AC-mandated clause the `run.sh` pins hold in both
> directions, so none can be dropped or shortened past that operative minimum. Both ceilings move
> over their #655 bases, each keeping the same ~4-word margin the #619/#640/#621/#655 cutovers use.
> The audited decision is `docs/cutovers/issue-707-focused-default-growth.md`, which carries the
> per-file byte deltas; the live measured figures are the *Measured* cells above.

## Net mandatory-prompt reduction, and the named justified-growth warning

- **Mandatory (always-loaded) prompt: net reduction of 32,787 words** — from 39,532 (monolith +
  extension, *all* of it loaded on every invocation) to 6,745 (thin root + live extension). This is
  the reduction the split exists to deliver: everything else now loads on demand, one step
  reference at a time. Both sides exclude the receiving extension (see Counting method). The
  *actual* always-loaded surface since issue #620 is the 9,003-word initial-load row above.

- **⚠️ `review-and-fix-split-cumulative-growth` (named justified-growth warning): +6,051 words.**
  The *normal cumulative path* (root + live extension + every reference a full run loads in
  sequence — the receiving extension excluded, per Counting method) is 45,583 words vs. 39,532
  before — a net **growth of +6,051 words** (+15.3%). Its drivers are
  the routing text the split itself adds (the *Step routing* table, the *Reference-loading
  contract* — entry-gate, canonical-boundary rule, per-reference failure map, always-resident
  re-read rule — the condensed terminal verdict→chat mapping, the durable-operand schema fields,
  and the per-reference `# Reference:` headers / `<!-- END … -->` markers), the park-calibration
  evidence gate merged in from `main` (issue #557 — the `parking_evidence`/`park_calibration` schema
  fields and the below-verdict-threshold evidence-classification prose in `shadow-review.md`, the
  bulk of the increase), the issue #609 `dispatched_effort` effort-observability schema key and its
  capture/write semantics, and the issue-#620 receiving-extension loader call plus the residual
  supersession-guard tail in the root (issue #640 relocated the guard's editor-authority mechanism
  out of the root into the always-loaded receiving extension — which this figure excludes — so it
  slightly *trimmed* the cumulative path), and the issue-#621 `settled-by-disclosure` foreclosure vocabulary threaded through the fix/park/shadow references, and the issue-#655 generic regenerate-on-conflict pointer added to `fixing.md`'s `CONFLICT` arm (the rule's own +952 lands on the two always-loaded *extensions*, whose term cancels out of this figure — only the reference-side pointer reaches it). It is **justified**: the split trades this cumulative increase for a
  32,787-word reduction in the *mandatory* prompt, on-demand sequential loading (only one step
  reference resident at a time — peak 20,342 words, not 45,583), and fail-closed reference handling.
  Cumulative token spend on a full run is not the metric the split optimizes; peak-context and
  per-step focus are.
