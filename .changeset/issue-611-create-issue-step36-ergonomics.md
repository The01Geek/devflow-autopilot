---
bump: patch
---

### Added

- `scripts/load-prompt-extension.sh` accepts an optional `--section '<## heading>'` flag that emits
  only the named section of a consumer prompt extension instead of the whole file, implementing the
  heading-extraction rule `skills/create-issue/SKILL.md` already specified. A section spans its
  heading line to the next line beginning `## ` (two hashes plus a space, so a `###` sub-heading is
  section content); duplicate same-heading sections concatenate in file order; headings inside HTML
  comment blocks and fenced code blocks are inert (both ``` and ~~~ fences, each closing only on
  its own kind), and an unclosed fence runs to end of file.
  Extraction uses bash builtins only. A flagless invocation stays byte-identical to the previous
  full-file behavior, with two extra-argument shapes now refused at exit 2 instead of ignored: an
  unrecognized `--`-prefixed argument, and a heading-shaped bare positional (a dropped `--section`,
  which would otherwise emit the whole extension). A bare plain word is still ignored (PR #617).
- The `stale-override` refusal in `scripts/issue-audit-state.py` now emits a state-aware recovery
  breadcrumb on stderr at both of its refusal surfaces (`query-eligibility` and `emit-body`). The
  arm is selected by the staling operand on the newest current-ordinal override rather than by the
  epoch's query-time arm, so a digest-bound override queried on an embed-arm epoch still gets the
  right remedy. `query-summary` output is unchanged (PR #617).

### Changed

- `/devflow:create-issue`'s four fresh extension re-load sites now request a single section instead
  of dumping the whole extension into context on every re-load (PR #617).
- The `record-dispatch` prose in `skills/create-issue/SKILL.md` shows `--round` at every arm, and
  the flag-requirement note states it is required on all of them — previously the note read as
  scoped to the degraded/inline pair, so a run following the file-arm or embed-retry sentence
  verbatim hit an argparse usage error (PR #617).
- The digest-bound override prose carries a canonical edit-sequencing rule: finish every draft-byte
  edit before recording a digest-bound override, and recover from a staled one by recording the
  revision, re-presenting, and taking a fresh explicit user election — never a bare
  record-revision-then-record-override pair (PR #617).

### Fixed

- An absent heading in a non-empty extension is now reported on stderr rather than passing
  silently, so a near-miss heading is observable; malformed `--section` usage is refused at exit 2
  instead of silently reverting to the full-file dump (PR #617).
