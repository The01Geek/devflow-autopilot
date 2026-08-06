---
bump: patch
type: Added
---

- **Add a behavioral eval (`scripts/implement-context-eval.py`) that measures the
  runtime main-thread context cost of `/prflow:implement` runs from a transcript
  corpus, plus a findings doc (`docs/internal/implement-context.md`).** The instrument
  reports, per run, the peak main-thread context; as a separate axis, how many times
  each of the four phase files was read — the multiplier the skill's cost shape is
  dominated by; the main-thread tool calls bucketed by category; and the distribution
  (median, max and total) of wall-clock gaps between consecutive main-thread tool calls,
  measured at turn granularity as a disclosed proxy, because a transcript record carries
  one timestamp however many tool calls its turn holds. Every axis is aggregated across
  the corpus with at least a median and a max. It is
  maintainer-run only: no skill, workflow, or suite gate invokes it for a measurement or
  a threshold, and it adds no size gate or threshold.
  The doc records the two corrections issue #1209 makes (the phase files load one per
  phase entry, and the re-read on every re-entry and after every nested-skill return is
  what matters) and declares a tier-conditional phase-file split a non-goal. (#1209)
