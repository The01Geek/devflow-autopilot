---
bump: patch
type: Security
---

- **Harden base-branch `.claude/settings.json` Stop-hook script sources in the review runner.** `claude-code-action` restores `.claude/` (the Stop-hook configuration) from the base branch, but the three hook commands exec script files under `lib/` and `scripts/` — not under `.claude/` — which the review job's PR-head checkout supplies, so a PR editing those targets could run unmediated shell at session end inside a secrets-bearing job, bypassing the `#402` deny-floor. `devflow-runner.yml` now overwrites each Stop-hook target with the trusted base-ref copy (or a fail-closed no-op stub) before `claude-code-action` runs, via the suite-driven helper `scripts/harden-stop-hooks.sh` executed only from a trusted source (base-ref copy, or the fetch-vendored copy) — mirroring the `#402`/`#404` trusted-source pattern. The implement job is unaffected: it checks out the default branch, never a PR head. (#458)
