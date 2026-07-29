---
bump: minor
---

### Changed

- The automatic pull-request-triggered review tier is **withheld from this release**.
  `.github/workflows/devflow-review.yml` is removed from the tree, and `install.sh` now
  copies only `devflow.yml` and `devflow-implement.yml` — a fresh installation receives none
  of `devflow-review.yml`, `devflow-runner.yml` or `telemetry-push.yml`. That tier's caller
  triggered on `pull_request`, `pull_request_target`, `check_run`, `workflow_run`,
  `check_suite` and `status`, called a reusable workflow with `secrets: inherit`, checked out
  the pull-request head, and carried no actor-authorization gate; issues #930 and #920
  describe the open defects, and neither is close to landing. The supported review path is
  unchanged: a repository collaborator with write, admin or maintain permission comments
  `/devflow:review` on a pull request, and `devflow.yml`'s `gate` job authorizes the actor —
  an outside fork contributor cannot self-trigger a DevFlow review. **A repository that
  already installed the three files keeps them**: `prune_stale_devflow_workflows()` is
  deliberately unchanged, so re-running the installer leaves them in place and the
  auto-review keeps working — which also means such a repository remains exposed to #930 and
  #920 for as long as `workflows["devflow-review"]` is `true` in its config. Removing the
  tier is a manual step, documented in `docs/workflow-triggers.md`: delete the three workflow
  files, set that key to `false`, and remove the `Devflow Review` context from any branch
  protection rule or ruleset that requires it. The removed caller's bytes are preserved on
  the `preserved/auto-review-tier` branch, whose `PRESERVATION.md` records the
  `devflow-runner.yml` object ID it was cut against; re-shipping the tier is a reconstruction
  against whatever that callee says at that later time, not a restore. (#936)

### Removed

- `scripts/derive-review-verdict.sh`, `scripts/derive-review-preconditions.sh` and
  `scripts/describe-skip-title.sh`. A sole-caller sweep resolved each one's only workflow
  caller to the removed `devflow-review.yml`, so all three became unreachable shipped code
  and are retired with it rather than left under live assertions.
  `scripts/render-guard-visibility.sh` is retained: `devflow-runner.yml`, which stays in the
  tree for the capability-profile generator and the review-profile lock, still names it as
  the sanctioned neutralizing renderer. (#936)
