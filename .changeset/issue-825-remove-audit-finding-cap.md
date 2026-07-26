---
bump: patch
type: Changed
---

- **`/devflow:create-issue` Step 3.6 audits no longer cap the auditor at five findings.** The
  fresh-context audit prompt's `Cap: at most five findings.` instruction is replaced by an
  explicit no-maximum instruction paired with a per-finding length discipline, so a draft with
  more than five real defects is no longer truncated to five, instead of costing the operator a
  round per five. No exhaustiveness is claimed: the change removes the numeric ceiling, it does
  not establish that a round found everything. Two results were registered on the issue's own
  drafting run. In a
  four-way dispatch over identical draft bytes the capped arm returned 5 while the three uncapped
  arms returned 15, 20 and 22 — two of those three reported stopping short of exhaustion, so 20
  and 22 are lower bounds rather than totals, and the capped arm was also the only one carrying
  the canonical template lens, making the contrast cap-plus-lens rather than cap alone.
  Separately, the capped arm returned exactly five on eight consecutive rounds against four
  different draft revisions — a ceiling-saturation result no lens hypothesis explains — and four
  defects reproduced independently by three or four of the four auditors had survived all eight
  of those rounds. The Quiet Killer keeps its semantics — one assessed
  slot rather than a quota, at most one qualifying finding, with `Quiet Killer: none` as an
  explicit alternative that is not itself a finding — and the Step 3.6 dimension-list growth
  policy is restated as a reporting-order rule grounded in the orchestrator's runtime
  main-thread context and per-dimension auditor precision rather than in a finding count. (#829)
