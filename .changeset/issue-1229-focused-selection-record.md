---
bump: patch
type: Added
---

- **Give the focused-first and single-flight rules a named place to record what the run did.**
  Added `scripts/focused_selection.py`, a named, round-trippable producer/reader for the
  focused-first selection record: per touched surface it records either the coverage-map entry
  consulted and the target selected (a discharging focused result) or the exemption ground that
  applied, plus whether the `scripts/verification-flight.py` single flight was consulted before a
  full-suite relaunch. The implement/review-and-fix/receiving-code-review prompt extensions now
  name that sink (the issue workpad for an implement run, `iter-<N>.json`'s
  `verification_evidence.focused_selection` for a standalone fix loop), complete the stale-prose
  rule with its positive action (commit the tree, then continue), and state that the single flight
  is consulted before a relaunch. `skills/implement/phases/phase-3-review.md` §3.2 now states that
  no verification round is owed between the `/simplify` commit and §3.3 — the `/simplify` edits
  ride into §3.3's first verification. No launch counter, launch ordinal, or mechanical
  changed-file-to-module routing is introduced. Its `encode` command rejects unparseable stdin,
  an unclassifiable surface entry, an unrecognized top-level key, and a missing `surfaces` with a
  one-line message rather than an unhandled traceback or a valid-looking marker for an empty
  record — so a run that followed the rule and one that was called wrongly cannot emit the same
  bytes (an empty record states itself as `{"surfaces": []}`; `single_flight_consulted` stays
  optional). Its read path validates the record shape without normalizing it: `decode_markers`
  now returns only well-shaped records, so a caller can index one safely, and the new
  `decode_marker_outcomes` keeps a marker that was present but rejected distinguishable from no
  marker at all and from a producer-recorded null, naming why it was rejected (the `decode`
  command breadcrumbs that to stderr). Unknown keys are tolerated on the read path so a record
  written by a later producer still reads back. (#1229)
