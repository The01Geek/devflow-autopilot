---
bump: patch
type: Changed
---

- **The test suite now reports skipped checks, and a skipped gate can no longer be recorded as a clean pass.** `lib/test/run.sh` gained a third tally — `SKIP` alongside `PASS`/`FAIL`, derived by the same mechanism — and every self-skipping check now routes through one `skip <name> <kind> <reason>` helper carrying a **kind** (`blocking-gate` for a real gate that should have run, `host-capability` for a condition the host cannot express). With nothing skipped the summary is byte-identical (`N passed, M failed`); with skips it reads `N passed, M failed, K skipped` followed by one line per skipped check. The summary renderer moved to `lib/test/summary.sh` (added to the CI shellcheck scope). `ci.yml`'s `lib + python tests` job now checks out full history (`fetch-depth: 0`) so `origin/main` resolves and the `#434` stale-prose self-scan runs live in CI instead of silently self-skipping. `/devflow:review-and-fix`'s `verification_evidence` gained a `skipped_checks` list, so a run whose suite reported skipped checks is never recorded as a clean pass. The suite exit code is unchanged — a skip never fails the suite. (#456)
