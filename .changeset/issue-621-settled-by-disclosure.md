---
bump: patch
type: Added
---

- **Add a `settled-by-disclosure` foreclosure disposition to the review deferral vocabulary.**
  A non-blocking review finding whose deliverable is an already-shipped disclosure — below the
  run's `verdict_severity_threshold` and not a REJECT driver — can now be recorded once with
  `skip_category: "settled-by-disclosure"` and a verifiable disclosure citation `{path, phrase}`
  instead of being re-litigated every pass. Within a run its repeat skip no longer trips the
  "Finding persists after pushback" stopping rule; across passes it rides the deferrals manifest
  into the PR-body Scope-Acknowledged block, where `scripts/match-deferrals.py` honors it through
  a new disclosure-verification guard (replacing the mutual-cross-link guard for this category
  only) that fails closed with `disclosure-unverified` when the cited phrase no longer verifies
  against the tree or the disclosure file is touched by the PR's own diff. No follow-up issue is
  filed — the disclosure is the deliverable. (#621)
