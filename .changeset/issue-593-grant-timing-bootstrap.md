---
bump: patch
---

Document the grant-timing bootstrap and make the create-issue mirror-sweep scope repo-wide (#593, PR #595).

### Added
- A `docs/cloud-setup.md` and `docs/implement-skill.md` statement that a tool grant added to `devflow_implement.allowed_tools` (or `devflow.allowed_tools`) inside a PR takes effect only after that PR merges, because the workflows resolve config grants at trigger time from the default branch — so a PR must not rely on a grant it itself ships.

### Changed
- The `.devflow/prompt-extensions/create-issue.md` `## Evidence axes` section gains a fifth "Grant-timing bootstrap" axis, and its three enumeration-mandating sites now state that a coupled-site sweep is repo-wide (a directory-scoped sweep does not discharge enumeration). Repo-internal `CLAUDE.md` and suite pins accompany the change.
