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
- **`scripts/match-deferrals.py`: compare diff paths on one canonical basis.** The
  self-foreclosure exclusion and the widens-surface hunk lookup compared raw paths against
  canonical `b/<path>` diff keys, so a non-canonical `disclosure.path` spelling
  (`./docs/x.md`, `docs//x.md`) could evade the exclusion and fail open. Both operands and the
  parser's keys now normalize. (#660 review)
- **`scripts/file-deferrals.py`: a surviving foreclosure no longer masks a complete filing
  failure.** When every fileable group failed but a `settled-by-disclosure` entry survived, the
  run exited 0 and the failed real deferrals dropped from the rewritten manifest untracked; it
  now exits 1 naming the arm. An all-foreclosure manifest (no fileable groups) still exits 0.
  (#660 review)
