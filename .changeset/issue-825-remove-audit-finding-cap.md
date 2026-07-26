---
bump: patch
type: Changed
---

- **`/devflow:create-issue` Step 3.6 audits no longer cap the auditor at five findings.** The
  fresh-context audit prompt's `Cap: at most five findings.` instruction is replaced by an
  explicit no-maximum instruction paired with a per-finding length discipline, so a draft with
  more than five real defects gets its whole finding set in one round instead of costing the
  operator a round per five. Measured on the issue's own drafting run, the capped auditor
  returned exactly five findings on eight consecutive rounds while uncapped auditors over the
  same bytes returned 15, 20 and 22 — and because two of those three reported stopping short of
  exhaustion, 20 and 22 are lower bounds rather than totals. Four defects reproduced by three or
  four independent auditors had survived all eight capped rounds. The Quiet Killer keeps its semantics — one assessed
  slot rather than a quota, at most one qualifying finding, with `Quiet Killer: none` as an
  explicit alternative that is not itself a finding — and the Step 3.6 dimension-list growth
  policy is restated as a reporting-order rule grounded in the orchestrator's runtime
  main-thread context and per-dimension auditor precision rather than in a finding count. (#829)
