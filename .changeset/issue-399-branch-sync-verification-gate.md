---
bump: patch
type: Changed
---

- **`receiving-code-review`: the Verification Gate now requires fresh branch-sync evidence before reception is reported complete.** A fourth numbered evidence item makes the agent regenerate branch-sync evidence in the same turn as the completion claim — divergence versus the remote counterpart (ahead and behind), divergence versus the base branch, and working-tree cleanliness — rather than relying on the one-shot Step 0 update from earlier in the session. On detected drift the Step 0 update is re-run once and the evidence regenerated; unpushed local commits are surfaced (pushing them stays governed by the surrounding workflow). The item inherits Step 0's fail-soft arms and is scoped to direct invocations (the autonomous fix loop's own branch-sync mechanics govern there); Step 0's section now states its update is point-in-time and not citable as completion-time evidence. (#400)
