---
bump: patch
---

Fixed: `synthesize_iter_workpads()` now declines synthesis (rc 3, no record written) when the pre-synthesis telemetry-branch fetch did not succeed (`_DEVFLOW_TELEMETRY_FETCH_STATUS` is `failed`/`unattempted`), mirroring the existing `_DEVFLOW_BASE_REF_STATUS` guard. Previously, a run whose telemetry fetch failed or was unattempted built the fix-commit exclusion set from an incomplete local ref and synthesized anyway, which could re-attribute a fix commit an earlier run already recorded (cross-PR telemetry double-booking). Existing misattributed records on `devflow-telemetry` are left as-is (fix-forward only).
