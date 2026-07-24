---
bump: patch
type: Added
---

- **Name the throwaway verification-scaffold reuse case in the implement + fix-loop engine
  prose.** Adds one per-surface-adapted advisory line to `skills/implement/phases/phase-2-implement.md`
  §2.3, `skills/receiving-code-review/SKILL.md`, and `skills/review-and-fix/references/fixing.md`:
  when RED/GREEN iteration builds a disposable rig to exercise code in isolation (a scratch repo,
  a fixture config, an interpreter/CLI wrapper), keep it under an already-ignored scratch path,
  record its location on the surface's own channel, and reuse it on later iterations instead of
  rebuilding it — but only after confirming it still exercises the current code shape (rebuild when
  that shape changed, so a stale rig is never reused into a false pass). Narrows the residual reuse
  gap the focused-module iteration default (#707) and §2.2.4's production-code Reuse gate leave open,
  adding no new gate, command, config key, or tool grant. (#754)
