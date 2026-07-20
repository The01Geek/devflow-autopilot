---
schema: 1
kind: growth
---

## Files

Issue #618 re-anchors the review-bundle word-budget gate to the shipped-default path and records a
maintainer-chosen **self-apply** standing remedy. That remedy must be encoded on the surface the
fix loop actually loads, and mirrored in the always-loaded project memory, so two mandatory census
rows grow:

- `.devflow/prompt-extensions/review-and-fix.md` (+1,025 bytes / +132 words) — gains the
  `## Review-bundle ceiling self-apply (issue #618)` section: the authorization for a
  `/devflow:review-and-fix` run to self-apply the escape-valve procedure on a growth breach, the
  `measured + 60` / three-mirror mechanic, the direct-`CLAUDE.md`-edit carve-out (a this-repo-scoped
  sibling of #366), the growth-only scope, and the pointer to the full decision record in
  `docs/review-bundle-budget.md`.
- `CLAUDE.md` (+693 bytes) — the review-bundle bullet is rewritten measured-figure-free: it drops
  the two live measured figures (30,082 and 32,339, which moved on every engine-prose PR and forced
  a `CLAUDE.md` edit each time) and instead carries the re-anchored **≤ 32,399-word** ceiling phrase
  (pinned by `lib/test/run.sh`), the shipped-default comparand definition, the self-apply
  authorization, and a pointer to the budget doc for all live figures. The net byte growth is the
  added authorization prose; the design intent is fewer future `CLAUDE.md` edits, not more.

No other mandatory census row moves. `skills/implement/SKILL.md` is **not** touched — the #366
implement-run carve-out is untouched; #618's self-apply carve-out is a *sibling*, encoded only in
the fix-loop surface and the project memory.

## Justification

The self-apply authorization is load-bearing, not decorative: the re-anchored ceiling carries a
thin 60-word margin by construction, so a concurrent merge that pushes the shipped-default path
over it turns the required suite RED with no code defect — a recurring event class (the same one
that motivated #618). The maintainer's recorded decision (Arm B, self-apply) ends that stall class
by letting a fix loop apply the escape valve itself. For the loop to do so it must (a) read the
authorization from a surface it loads — the `review-and-fix` extension — and (b) be permitted to
edit `CLAUDE.md`'s ceiling-phrase mirror directly, because the `CLAUDE.md` ceiling pin would
otherwise keep the suite RED after the escape valve is applied, trapping the very loop that is
remedying it. The bytes belong on the **mandatory** path because the authorization must be present
whenever a fix loop hits that RED, which is not a rare-path condition.

## Budget renegotiation (review-and-fix initial load and max active step)

`.devflow/prompt-extensions/review-and-fix.md` was sitting **~4 words** below its documented
initial-load ceiling — root 3,213 + extension 2,473 = 5,686 words against a 5,690 ceiling — so the
mandated section could not fit under it at any phrasing. The section was written to its operative
minimum (the authorization, the `+60`/three-mirror mechanic, the direct-edit carve-out, the
growth-only scope, and the doc pointer), and only then were the two affected ceilings renegotiated:

- **initial load 5,690 → 5,824** (measured 5,818, ~6 words headroom, mirroring the #556/#619 style),
- **max active step 17,000 → 17,086** (measured 17,080, ~6 words headroom).

`lib/test/run.sh`'s `RAF_LOAD_CEIL` / `RAF_MAXSTEP_CEIL` and every coupled cell in
`docs/review-and-fix-budget.md` (the ceilings table, the Measured cells, the live-extension row,
the initial-load / cumulative / max-step word cells, and the net-reduction from/to pair) are
updated in this same change. The **growth-delta (+4,323 words)** and **net-reduction (32,988
words)** figures are unchanged: the live extension term appears on both sides of each subtraction
and cancels, so a 132-word extension edit moves the cumulative and initial-load cells without
perturbing the split-isolating growth or reduction figures.

The `lib/test/prompt-mass-baseline.json` mandatory-byte census baseline is regenerated in the same
change for the two grown rows (review-and-fix.md 16,546 → 17,571; CLAUDE.md 63,409 → 64,102). This
artifact is the audited decision that both widenings record.
