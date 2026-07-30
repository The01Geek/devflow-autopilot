---
bump: patch
---

### Changed

- The published one-pagers under `docs/site/` now live on the `gh-pages` branch, which GitHub
  Pages publishes directly ("deploy from a branch"). A marketplace `/plugin install` shallow-clones
  the repository and copies the whole subtree unfiltered, so the built HTML under that directory
  was 4.26 MB of a 10.64 MB packed clone reaching every installing user — and that cost recurred on
  every `marketplace update`, which re-clones rather than fetching incrementally. The published
  URLs are unchanged.
- `agents/silent-failure-hunter.md` no longer instructs the reviewer to look for an error ID in
  `constants/errorIds.ts`, or to grade logging against `logForDebugging` / `logError` / `logEvent`.
  Those names came from the upstream `pr-review-toolkit` project and describe an unrelated
  codebase, so the agent was directing reviewers at files and helpers that are not there in either
  this repository or the consumer repositories it reviews. It now establishes
  the reviewed project's own logging and error-reporting conventions before grading them, and
  treats a recommendation naming a helper the repository does not have as a false finding.

### Removed

- `.github/workflows/pages.yml`. GitHub Pages now builds from the `gh-pages` branch, so the
  Actions-based deploy is no longer part of the publishing path.
- The per-run review workpads formerly tracked under `.devflow/logs/review/`. Issue #441 already
  made the `devflow-telemetry` branch their canonical home — `lib/efficiency-trace.sh` reads them
  from there and keeps the working-tree glob only as a fallback for a consumer's pre-#441 archive.
  Each of those workpads, and each `fix_commit_sha` it recorded, is preserved on that branch.
