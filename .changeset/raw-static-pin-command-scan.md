---
bump: patch
type: Fixed
---

- **Harden raw static-pin command scanning.** Bind raw presence matches to executable shell positions, cover pipeline/background/subshell boundaries, and fail closed when multiple raw guards share one logical line. (#860)
