---
bump: patch
type: Changed
---

- **Record a `Verification evidence:` marker on every tier that maintains a workpad, once per whole-suite launch.** The implement/review-and-fix/receiving-code-review prompt extensions now bind the `Verification evidence:` obligation to every tier — cloud `/prflow:implement` included, not only local/interactive — and require one record per whole-suite launch (distinguished by the coordinator's per-launch run root, with no launch counter), so a repeated or failed cloud launch is legible in the repository's own records rather than recoverable only from a run transcript. The shared review-engine advisory now acts on cloud-classified PRs too, and `lib/cheap-gate.jq`'s head comment is reconciled to drop the superseded population-coverage reason. (#1249)
