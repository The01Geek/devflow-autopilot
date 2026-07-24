---
bump: patch
type: Changed
---

- **Adopt a go-forward single-source-of-truth documentation/contract policy and redirect the retrospective remedy heuristic.** The `retrospective-audit` skill's proposal-selection step now prefers collapsing a drift/desync/coupled-mirror root cause to a single canonical source over adding a new pin plus a mirror copy, so the self-improvement loop stops proposing remedies that grow the redundancy apparatus that caused the drift. (#762)
