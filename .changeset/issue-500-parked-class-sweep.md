---
bump: patch
type: Fixed
---

- **Run class-generalization checks over parked findings before shadow review.** The fix loop now discovers and registers actionable sibling findings even when convergence has no fix-triggered sweep, while preserving fail-closed calibration, bounded dispatch, and current-iteration accounting. (#510)
