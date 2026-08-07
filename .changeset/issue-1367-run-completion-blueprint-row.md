---
bump: patch
---

Review engine: the progress comment's `## Blueprint` gains a final row representing completion of everything the run owed. On the standalone `/prflow:review` path the row is ticked only when the delivery helper reports `POSTED review <event>` or `POSTED comment <event>`; on the `/prflow:review-and-fix` path, which posts no verdict to GitHub, it is ticked at Loop Exit and asserts only that the loop reached its terminal work. A run that reached the verdict-aggregation write and then failed or skipped delivery previously ticked its last row and read complete anyway; it now leaves a visibly incomplete checklist and states why. Before terminating, the standalone path re-reads its own Blueprint and makes one bounded attempt to complete a missing delivery. The `Status` field goes terminal at the same point in the run as before.
