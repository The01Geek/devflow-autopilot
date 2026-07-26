---
bump: patch
type: Fixed
---

- **The Phase-3 final-pass reviewer now receives an already-resolved prompt-extension command instead of resolving its own anchor.** The reviewer is dispatched as a `general-purpose` Task with no skill-directory anchor, so it improvised shell shapes the cloud matcher refuses and silently lost consumer `requesting-code-review` prompt extensions. The orchestrator now resolves the helper path and supplies the granted leading-token command (`.devflow/vendor/devflow/scripts/load-prompt-extension.sh requesting-code-review` on the cloud tiers, its own anchor-resolved path otherwise); the reviewer runs it verbatim and reports one of three status tokens, so a refusal is surfaced (via a fail-closed notice-suppression flag) and recorded in the caller's sink, while the routine local-tier denial is recorded as `unestablished` and never inflates `reflections[]`. The Step 2.6 shadow dispatch carries the same command, and the shape-lint corpus now covers `requesting-code-review`/`receiving-code-review`. Adds no tool grant on any profile. (#819)
