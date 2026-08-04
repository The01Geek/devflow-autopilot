---
bump: patch
type: Fixed
---

- `/prflow:review-and-fix` now carries its own Cloud command-shape discipline in the bundle root, so an agent that meets a matcher denial on the `command` tier switches to a permitted shape instead of improvising a second variant. Step 0.5 is now a fail-closed gate that proves the checked-out branch is the PR head before any diff or review work and stops with a named cause on a mismatch or a failed `gh pr checkout`. Removed the fence-less `.prflow/tmp/` ignore-coverage instruction that provoked an improvised `git check-ignore` (granted on no profile), and documented the conditional push-mode re-review consequence. (#1305)
