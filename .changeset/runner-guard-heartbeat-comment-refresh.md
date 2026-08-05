---
bump: patch
type: Fixed
---

- **Correct a stale clause in the runner's PreToolUse guard-heartbeat comment.** The comment
  block above the guard-visibility step described the heartbeat as written "on every
  invocation including a defer/allow", naming two `permissionDecision` tokens that
  `scripts/pretooluse-shape-guard.py` no longer emits — its `defer` fall-through was replaced
  with a true no-decision path (exit 0 with no stdout) after that token was measured to block
  the tool and end the process, and `allow` was never emitted. The clause now names the
  no-decision fall-through and records that `deny` is the guard's only decision token.
  Comment prose only — no executable content changed, and the four-outcome disambiguation the
  block describes is unaffected. (#1323)
