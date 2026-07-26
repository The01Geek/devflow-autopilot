---
bump: patch
---

### Added

- Implement Phase 2.3 gains `2.3.0d`, a describing-prose reconciliation sweep armed on the edits the existing trigger set does not cover: **removing** a member from an enumerated value set (code-defined or doc-enumerated), and **weakening** a universal the change previously asserted (softening, scoping, or removing it). It reconciles prose a change made false *without editing the claim* — describing prose that names no member literal, which `2.3.0b`'s member-literal search structurally cannot reach, and surviving full-strength copies of a weakened claim in other directories. Its enumeration is repo-wide and reuses `2.3.0` step 2's existing normalized search rather than inventing a second technique, and it carries an explicit unrunnable arm so an absent tool or a denied search records a named backstop instead of a clean pass. The `/devflow:review-and-fix` loop inherits it through the existing sweep-index re-anchor in item 3b of Step 3, with no edit to that item's import.
- The Step 3.5 fix-delta verification gate gains a further check: for each assertion the fix delta adds, the blinded subagent identifies the regression that assertion's own name and description claim it catches and reports whether the assertion *as reported* singles that regression out — naming the reportable outcomes (no state change under the named regression; a state change under a different cause; a reported identity indistinguishable from a sibling arm). An assertion whose target cannot be read is reported **unestablished**, never clean.

### Changed

- The Step 3.5 gate's dispatch scope admits a bounded read of each added assertion's own target for the new check alone, and its severity-graded routing arms are scoped to the two pre-existing checks so every gate input has exactly one applicable disposition. The new check's disposition inherits the gate's existing 2-inner-attempt cap, cap-counting promotion, and at-cap carry into the convergence shadow.
- `fixing.md` item 3b now distinguishes a sweep's **trigger**, which is scoped to the fix delta without exception, from a triggered sweep's **enumeration**, which may exceed the delta only where that sweep's own Phase 2.3 definition states a repo-wide domain (`2.3.0`, `2.3.0a`, `2.3.0b`, `2.3.0d`); every other sweep's enumeration stays delta-bounded. Both of item 3b's statements of the bound carry the distinction.

### Fixed

- `fixing.md` item 3a's locate step instructed `git grep -n`, which item 3b in the same file prohibits and which no capability profile grants — so the step was silently refused on both cloud tiers. It now instructs the granted command forms item 3b names, and the implement Phase 2.3 prose's own `git grep -n` instructions are reconciled to those same forms.
- `docs/DEVFLOW_SYSTEM_OVERVIEW.md` and `docs/shadow-review.md` described the Step 3.5 gate as firing on every iteration unconditionally while omitting its no-fix skip arm, and the overview's item-3b bullet pointed at a page carrying no item-3b content. Both are corrected, and both pages now describe the gate's third check.
