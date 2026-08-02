---
bump: patch
type: Added
---

- **`/prflow:create-issue` now offers to self-assign the new issue.** After you approve the rendered draft and before the issue is created, the skill asks "Assign this issue to you?"; answering yes adds `--assignee "@me"` to the `gh issue create` call so ownership is set in the same atomic create, answering no files it unassigned, and silence or an unclear reply pauses and re-asks rather than guessing. Draft-only requests are unchanged and trigger no assignment prompt. (#1168)
