---
bump: patch
---

Detect and truthfully report the verdict-post `gh api` bypass (#1250)

A cloud run that cannot reach the verdict-post helper could still create a real,
merge-blocking pull-request review by calling the reviews endpoint directly through the
granted `gh api` — a review GitHub records but which carries no producer-emitted verdict
marker, so no verdict-derivation consumer reads it as a verdict. The run's own reach
record then falsely stated it "left the reviews API and `reviewDecision` untouched".

- New `scripts/classify-head-reviews.sh`: a closed-vocabulary classifier
  (`none | marked | unmarked <id>… | unestablished <reason>`, always exit 0) over the
  reviews recorded on the reviewed head, scoped to the run's own reviewer identity. It
  places each review by the issue-#1247 precedence — the verdict marker's `head=` is
  authoritative and the reviews-API `commit_id` is only a fallback — so a markerless own
  review it cannot place off the head grades `review-placement-unprovable` instead of
  reaching `none`, the one arm that reports the reviews API as untouched.
- The `devflow.yml` reach-record step now queries the reviews API, classifies them, and
  passes the token to `scripts/describe-verdict-post-gap.sh`, which stops asserting the
  API was untouched when it was not, names the offending review on the unmarked arm, and
  asserts nothing either way when the classification cannot be established.
- No capability profile changes: the grant cannot express the read/write distinction, so
  the control is downstream. Corrected the falsified "sole granted post path" prose in
  `docs/DEVFLOW_SYSTEM_OVERVIEW.md` §8, `CLAUDE.md`, and the capability-profiles test
  module, and recorded that unmarked reviews remain producible on the cloud tiers, so the
  transitional-prose retirement criterion is not yet satisfiable.
