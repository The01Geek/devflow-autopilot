---
bump: patch
---

Redact operator home-directory paths from retrospective records on the merge write path.

`lib/materialize-retrospectives.sh` now rewrites operator home-directory prefixes
(`/Users/<name>/`, `/home/<name>/`, `<drive>:\Users\<name>\`) to `~` in every string
value of every record it merges, at the single deterministic merge write choke point,
so no producer can leak an account name or machine layout into the tracked, published
`.devflow/learnings/` corpus. GitHub-Actions runner paths (`/home/runner/`,
`/home/runneradmin/`) and every other string are preserved unchanged, keeping the
corpus's value as an unsanitized record of the bot's friction. The redaction is
expressed through the resolved `$DEVFLOW_JQ`, applies only to string-typed values via
`walk`, and preserves each record's `.pr`/`.kind` merge key. The single pre-existing
leaked operator path is scrubbed from both corpus files, and `SECURITY.md` /
`CONTRIBUTING.md` now name the corpus as committed content that must be kept free of
host-local and owner-identifying data. (#672)

`scripts/stale-prose-lint.py` no longer examines diff-added lines under
`.devflow/learnings/` or `.devflow/logs/`. Those records quote reviewed prose verbatim as
JSON data about a past PR, never as an assertion about the file they sit in, so rewriting
one — as the redaction above does — re-presented the whole record as diff-added prose and
graded a previous PR's counted claim STALE. Each excluded path is named on stderr, and
`CHANGELOG.md` / `.changeset/` stay in scope. (#672)
