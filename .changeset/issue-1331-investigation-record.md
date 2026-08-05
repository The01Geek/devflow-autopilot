---
bump: minor
type: Added
---

- **`/prflow:create-issue` now splits its output into an implementer brief plus a gated investigation-record comment.** Drafting sorts content into two buckets as it is written — the issue body carries the implementer's brief (what is broken, what "done" looks like, which files to start in, which hazards matter), and a separate **investigation record** (rejected designs, refutation prose, confirmatory evidence, deliberation, lower-severity hazards) is posted as the first comment on the created issue, with its workflow-trigger tokens neutralized. The boundary is the vanish test — *if this sentence vanished, would the implementer build the wrong thing?* — with five body sections that never move (`## Dependencies`, `## Acceptance Criteria`, the `- **Documentation Needed**` bullet, `## 🚫 Blocked`, and every `Verified:` bullet), each parsed by a named in-repo consumer. The new `create_issue.investigation_record_enabled` config key (default `true`) gates publication only; sorting always runs. (#1331)
