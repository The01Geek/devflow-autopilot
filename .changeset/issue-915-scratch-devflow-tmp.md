---
bump: patch
---

Move `/devflow:implement` and `/devflow:review-and-fix` engine scratch off the cloud-denied bare `/tmp/` paths onto the probe-permitted repo-relative `.devflow/tmp/` directory (issue #915). On the read-write `devflow-implement` matcher profile a granted head carrying a `/tmp` redirect is silently denied, so Phase 1/2/4 scratch reads were being lost with no error. Every migrated writing fence now creates its scratch leaf with an rc-checked `mkdir -p` and deletes any stale target before writing. A new desk-time gate — rule `IR4` in `lib/test/extract-command-shapes.py --profile implement` — turns a reintroduced `/tmp` redirect RED, mirroring the review tier's R3 redirect arm (without R3's heredoc arm, permitted on this tier). `scripts/preflight.py` now emits a stderr breadcrumb when its stop-verdict payload falls back to the system temp dir a cloud agent's Read tool cannot reach.
