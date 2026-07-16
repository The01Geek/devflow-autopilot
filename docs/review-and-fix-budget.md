# Review-and-Fix split — prompt budget (issue #530)

This table records the prompt-surface budget of `/devflow:review-and-fix` before and after the
issue #530 split of its monolithic `SKILL.md` into a thin root + step references under
`skills/review-and-fix/references/`. It is the checked-in artifact for the #530 word-budget
acceptance criteria; the live regression guard is the `#530 budget` block in `lib/test/run.sh`
(root ≤ 3,000 words; root + live extension ≤ 5,500 words; root + extension + max active step
≤ 15,000 words).

## Counting method & formulas

- **lines / words / bytes** are `wc -l` / `wc -w` / `wc -c` of each file (the same tools the
  `run.sh` guard uses). **approx tokens = words × 1.3** (a coarse English-prose estimate; stated
  as a formula, not a measured tokenizer count).
- **live extension** = `.devflow/prompt-extensions/review-and-fix.md` (this repo's own extension;
  a consumer's extension cost is measured separately and added to the plugin-root row — no global
  consumer-extension ceiling is claimed).
- **actual initial load** = plugin root + live extension (what is *always* loaded at invocation).
- **bundle** = plugin root + every `references/*.md` (the whole shipped skill surface).
- **normal cumulative path** = root + extension + every reference a converging run loads in
  sequence (Σ references; the maximal case — a clean immediate-APPROVE run loads fewer).
- **maximum active step** = root + extension + the single largest step reference
  (`shadow-review.md`), the peak when exactly one step reference is resident at a time.

## Before / after

| Row | Included paths | Lines | Words | Bytes | ≈Tokens |
| --- | --- | ---: | ---: | ---: | ---: |
| **BEFORE** — monolith | `skills/review-and-fix/SKILL.md` (pre-split) | 1,134 | 36,208 | 250,928 | 47,070 |
| **BEFORE** — always-loaded | monolith + live extension | 1,330 | 38,635 | 266,909 | 50,226 |
| live extension | `.devflow/prompt-extensions/review-and-fix.md` | 196 | 2,427 | 15,981 | 3,155 |
| **AFTER** — plugin root | `skills/review-and-fix/SKILL.md` (thin) | 284 | **2,994** | 23,470 | 3,892 |
| **AFTER** — actual initial load | root + live extension | 480 | **5,421** | 39,451 | 7,047 |
| **AFTER** — bundle | root + all `references/*.md` | 1,234 | 37,404 | 259,972 | 48,625 |
| **AFTER** — normal cumulative path | root + extension + Σ references | — | 39,831 | — | 51,780 |
| **AFTER** — maximum active step | root + extension + `shadow-review.md` | — | **14,986** | — | 19,482 |
| reference: `shadow-review.md` | Step 2.6 | 214 | 9,565 | 66,503 | 12,435 |
| reference: `fixing.md` | Step 3 | 154 | 8,321 | 56,116 | 10,817 |
| reference: `loop-exit.md` | Loop Exit | 270 | 6,490 | 44,465 | 8,437 |
| reference: `loop-control.md` | workpad + field semantics + Main Loop + Steps 0.5–2 | 184 | 4,840 | 33,805 | 6,292 |
| reference: `pre-fix-gates.md` | Step 2.5 + parked-class sweep | 49 | 1,996 | 14,341 | 2,595 |
| reference: `fix-delta-gate.md` | Step 3.5 | 27 | 1,376 | 9,312 | 1,789 |
| reference: `error-handling.md` | When NOT to use + Error Handling + Common Mistakes | 28 | 1,055 | 6,880 | 1,372 |
| reference: `convergence.md` | Step 4.5 | 24 | 767 | 5,080 | 997 |

## Budget ceilings (all met)

| Ceiling | Value | Measured | Result |
| --- | --- | ---: | :--: |
| Plugin root ≤ 3,000 words | 3,000 | 2,994 | ✅ |
| Root + live extension (initial load) ≤ 5,500 words | 5,500 | 5,421 | ✅ |
| Root + extension + max active step ≤ 15,000 words | 15,000 | 14,986 | ✅ |

## Net mandatory-prompt reduction, and the named justified-growth warning

- **Mandatory (always-loaded) prompt: net reduction of 33,214 words** — from 38,635 (monolith +
  extension, *all* of it loaded on every invocation) to 5,421 (thin root + extension). This is the
  reduction the split exists to deliver: at least 33,134 words below the measured combined baseline
  (33,214 ≥ 33,134). Everything else now loads on demand, one step reference at a time.

- **⚠️ `review-and-fix-split-cumulative-growth` (named justified-growth warning): +1,196 words.**
  The *normal cumulative path* (root + extension + every reference a full run loads in sequence)
  is 39,831 words vs. 38,635 before — a net **growth of +1,196 words**. This growth is the routing
  text the split adds: the *Step routing* table, the *Reference-loading contract* (entry-gate,
  canonical-boundary rule, per-reference failure map, always-resident re-read rule), the condensed
  terminal verdict→chat mapping, the durable-operand schema fields, and the per-reference
  `# Reference:` headers / `<!-- END … -->` markers. It is **justified**: the split trades this
  small (+3.1%) cumulative increase for a 33,214-word reduction in the *mandatory* prompt, on-demand
  sequential loading (only one step reference resident at a time — peak 14,986 words, not 39,831),
  and fail-closed reference handling. Cumulative token spend on a full run is not the metric the
  split optimizes; peak-context and per-step focus are.
