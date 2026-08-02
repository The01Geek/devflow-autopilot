---
bump: patch
type: Fixed
---

- **`/prflow:review-and-fix` can now resolve the review-engine bundle on every tier where the engine is present on disk.** Engine location no longer uses a `Glob` for `**/devflow/skills/review/SKILL.md` — a pattern that stopped matching any layout after the `.devflow/` → `.prflow/` rename and depended on unestablished file-search-tool semantics. Resolution now walks an ordered, repo-root-anchored candidate list (the repo-root `skills/review`, then `.prflow/vendor/prflow/skills/review`, then the superseded `.devflow/vendor/devflow/skills/review`), reading each candidate's `SKILL.md` directly, resolved once per engine entry. The engine bundle now binds its phase references and root-identity hashing to the **caller-located** directory rather than re-resolving the runner anchor, so a caller that reached the root by reading it as a file derives a complete manifest instead of stopping at `identity: underived`. When no candidate resolves, the run still stops with a message naming `/prflow:init`. (#1085)
