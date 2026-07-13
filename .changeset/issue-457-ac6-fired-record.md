---
bump: patch
type: Fixed
---

- **Correct the stale AC6 Stop-hook record and its three now-false pre-merge prose sites.**
  `docs/execution-file-shape.md`'s AC6 section now records the observed result — **FIRED**,
  a base-branch `.claude/settings.json` `Stop` hook does execute under `claude-code-action`
  (run `29224205805`, 2026-07-13) — as a dated one-action-version observation with the
  pre-merge two-step narrative removed and the security corollary (#458) linked. The
  now-false "expected on a probe PR / only effective once merged" framing in
  `scripts/describe-hook-probe.sh`'s did-not-fire arm and the "SHIPS in this PR / must be
  merged" comment in `.github/workflows/matcher-probe.yml` are rewritten to say that, the
  hook being on base, an absent marker is an anomaly (pointing at the job-log stderr
  breadcrumbs); the no-launder warning is preserved verbatim. (#457)
