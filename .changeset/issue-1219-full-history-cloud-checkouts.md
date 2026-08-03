---
bump: patch
type: Fixed
---

- **The two agent-running cloud jobs now check out full history, so the test suite's
  historical-baseline gate can actually run.** `devflow-implement.yml`'s `claude` job and
  `devflow.yml`'s `command` job both ran the suite in-env from a `fetch-depth: 50` checkout.
  The suite's baseline-corpus control resolves a fixed past commit through
  `git show <ref>:<path>`; under a bounded depth that commit does not resolve, so the control
  self-skipped with kind `blocking-gate` — and the implement completion gate admits no skip
  population at all, so the run could not finish on that result and had to unshallow and
  repeat the whole shard (4 min 20 s of discarded work on the measured run). Both jobs now
  use `fetch-depth: 0`, matching `ci.yml`. A targeted fetch of the required commits was
  rejected because it would couple the workflow to the ref list inside the test suite and
  silently stop covering it whenever that list changes; the reasoning is recorded in each
  checkout's own comment. Consumer repositories inherit the new depth on their next
  `install.sh` run, which fixes the same class of failure for any check of their own that
  needs history older than the last 50 commits. (#1219)
