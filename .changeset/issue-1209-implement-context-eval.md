---
bump: patch
type: Added
---

- **Add a behavioral eval (`scripts/implement-context-eval.py`) that measures the
  runtime main-thread context cost of `/prflow:implement` runs from a transcript
  corpus, plus a findings doc (`docs/implement-context.md`).** The instrument reports,
  per run, the peak main-thread context and — as a separate axis — how many times each
  of the four phase files was read, the multiplier the skill's cost shape is dominated
  by; it aggregates a median and max across a corpus. It is maintainer-run only: no
  skill, workflow, or test-suite gate invokes it, and it adds no size gate or threshold.
  The doc records the two corrections issue #1209 makes (the phase files load one per
  phase entry, and the re-read on every re-entry and after every nested-skill return is
  what matters) and declares a tier-conditional phase-file split a non-goal. (#1209)
