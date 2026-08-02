---
bump: patch
type: Fixed
---

- **A review verdict's identity is now a producer-emitted marker, not the shape of agent prose.**
  A census over 60 pull requests found 6 of 9 real bot `CHANGES_REQUESTED` review bodies matching
  none of the shapes the merge-gate consumers looked for, so each was silently read as "not one of
  ours": the stale-REJECT dismissal reported a clean no-op on a wedged pull request, and the weekly
  retrospective's "merged over an un-cleared REJECT" detector reported clean on pull requests it
  could not classify. `scripts/post-review-verdict.sh` now takes the verdict token, chooses the
  review channel itself, and stamps
  `<!-- prflow:review-verdict head=<40-hex> verdict=<APPROVE|REJECT> -->` as line 1 of the review
  body and as the line after the run key in the run-keyed progress comment; when the review post is
  refused it posts the same marker-stamped body to the comment channel and says so, and when no
  durable channel takes the verdict it emits a distinct token and exits non-zero.
  `dismiss-stale-rejections.sh`, `derive-review-verdict.sh`, `lib/fetch-pr-context.sh` and
  `build-experiment-records.py` read that marker as their first signal while keeping their existing
  prose arms for reviews already posted on long-lived open pull requests, whose retirement is
  confirmation-gated on a maintainer-runnable sweep rather than on a date. `Bash(gh pr review:*)` is
  withdrawn from the `review`, `implement` and `command` capability profiles, so on the cloud tiers
  the only granted post path is the one that stamps. (#1148)
