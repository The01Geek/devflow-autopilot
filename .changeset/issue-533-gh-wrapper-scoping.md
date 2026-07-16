---
bump: patch
type: Fixed
---

- **Scope gh-fresh wrapper selection to PATH; stop publishing a process-global `DEVFLOW_GH`.** The two writer workflows' byte-identical fresh-gh install steps are replaced by one checked-in installer, `scripts/install-gh-wrapper.sh`, which validates seven setup outputs fail-closed (stopping the job before the agent with a diagnostic naming the failed output), fingerprints the job-start token with the preflight-guaranteed python3 `hashlib` (no `sha256sum`/`shasum`/`awk` dependency), and publishes only `DEVFLOW_GH_REAL` plus the `GITHUB_PATH` prepend. The old `DEVFLOW_GH` export to `GITHUB_ENV` leaked into later job steps — including the repository test suite, where it outranked fixture PATH stubs by resolver design; `DEVFLOW_GH` remains the explicit caller/test override seam, and `lib/test/run.sh` now clears an inherited value at entry. (#538)
