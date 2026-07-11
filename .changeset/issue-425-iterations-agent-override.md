---
bump: patch
type: Added
---

- **`agent_overrides` entries accept an optional `iterations` key.** Its only valid value is
  `first-only`; an agent whose resolved override carries it is excluded from the Phase-3 review
  roster on `/devflow:review-and-fix` fix-loop iterations ≥ 2 (enforced engine-side). The key is
  **default-off** — absent, behavior is byte-identical to today, so consumer repos are unaffected
  unless they opt in. It is a no-op in standalone `/devflow:review` (a single pass) and is never
  applied to the Step 2.6 shadow fan-out, whose blinded audit always keeps the full roster. An
  out-of-enum value is dropped with a warning, mirroring the invalid-`effort` path; the run never
  aborts. DevFlow's own tracked config scopes `devflow:code-reviewer` to `first-only`. (#425)
