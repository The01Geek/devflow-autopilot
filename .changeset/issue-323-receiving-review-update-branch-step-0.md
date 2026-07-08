---
bump: patch
type: Added
---

- **`receiving-code-review`: added an update-the-branch step 0 to the Response Pattern.** The
  fix loop now opens by updating the working branch — fetch from the remote, merge in the
  branch's remote counterpart when it has commits the local branch lacks, then merge the base
  branch into the working branch — before reading any feedback, so review fixes are written,
  tested, and verified against the code that will actually merge instead of a stale snapshot.
  The step checks each fetch's and merge's exit status and working-tree state so a failed fetch
  or a conflicted merge is detected rather than passed over silently. Merge conflicts these
  updates raise are resolved as part of the current work; the step is fail-soft when there is
  nothing to update from. (#326)
