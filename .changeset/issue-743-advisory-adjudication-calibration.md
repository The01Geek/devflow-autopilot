---
bump: patch
type: Added
---

- **Step 3.6 advisory and invalid grades are now durable, user-visible, and
  calibration-checked before convergence.** Each advisory or invalid adjudication carries a
  durable per-finding record — a one-line summary and rationale, an impact-class tag, and the
  auditor's returned finding block byte-preserved up to the evidence cap (a longer block is
  truncated with the truncation disclosed in the stored bytes) — recorded through the state owner
  (`record-adjudication --advisory-records-file`/`--invalid-records-file`, refused when a
  class count and its supplied records disagree, or on an empty/record-splitting/protocol
  or out-of-set-tag field), read back with `query-adjudication-records`, and rendered to the
  user before the approval election (`record-adjudication-render`). A never-blocking
  calibration layer (`query-calibration`, a `calibration=` sibling of the coverage boundary
  offer) surfaces an advisory grade on an impact-bearing finding
  (`implementation-correctness`/`scope`/`safety`/`verifiability`) that carries no recorded
  evidence, so an under-evidenced grade is named to the maintainer rather than silently
  converged past. Filing is never blocked on any arm. The pre-#743 call shape (zero advisory
  and zero invalid) is byte-identical. Evidence record:
  `docs/advisory-adjudication-calibration.md`. (#743)
