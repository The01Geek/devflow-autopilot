---
bump: patch
type: Fixed
---

- **`/prflow:create-issue` Step 3.6 now refuses a file-arm audit dispatch whose draft bytes are absent from the run's recorded byte history.** A scoped ("targeted") audit round computes its delta against the bytes an earlier round dispatched, recovered from the staged-write history. When the canonical write was never recorded there, that operand is missing — and because a missing operand degrades the round-kind selection to the cold whole-draft kind rather than aborting, the loss was silent, so every round after the first paid for a full re-audit. `record-dispatch` now resolves that recoverability before it writes any state and refuses with a named breadcrumb (`file-arm-requires-staged-write`) that names the remedy, mirroring the `file-arm-requires-stdin-digest` refusal `record-revision` already carries. The refusal is scoped to a fresh file-arm dispatch: the embed and inline arms are entered precisely when no canonical write landed, and a retry re-dispatches an already-open round. (#1113)
