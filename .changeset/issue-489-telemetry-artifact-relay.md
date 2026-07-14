---
bump: patch
type: Added
---

- **Auto-review telemetry now reaches the `devflow-telemetry` branch via a trusted cross-workflow
  relay.** The read-only auto-review tier (the merge-gating judge, and the most frequent cloud run)
  stages its observability artifacts but has no write credential to push them, so they were
  discarded at runner teardown. Now `devflow-runner.yml` uploads the staged records as a workflow
  artifact, and a new trusted `telemetry-push.yml` job — triggered via `workflow_run`, minting a
  write-capable App token above its checkout and never checking out the PR head — downloads,
  validates, and pushes them through the existing `lib/telemetry-branch.sh` write path. The
  downloaded artifact is treated as untrusted PR-influenced input: `scripts/validate-telemetry-artifact.sh`
  gates it all-or-nothing (rejecting symlinks, absolute/traversal paths, disallowed paths,
  over-cap entry-count/size, and non-record-shape JSON) before anything is staged, so a hostile
  artifact is dropped whole with a `::warning::` and the branch is never mutated. (#495)
