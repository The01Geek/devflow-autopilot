---
bump: patch
---

### Fixed

- Two shipped skill snippets expanded an unquoted filename pattern with no guard, so under zsh's default `nomatch` the command was skipped and the enumeration came back silently empty in a consumer repo that lacked the matching directory. `skills/implement/phases/phase-1-setup.md`'s agent enumeration and `skills/docs-bootstrap-internal/SKILL.md`'s top-level structure survey now carry the `setopt nonomatch` guard and report the empty case explicitly.

### Added

- A written portability convention in `CLAUDE.md` stating that shell snippets in skill files must survive a non-bash interactive shell, naming the zsh unmatched-glob behaviour and giving the guard line as the standard remedy — plus a note that `\b` is a GNU extension BSD `sed`/`grep -E` accept while matching nothing, with `(^|[^a-zA-Z_])` as the portable replacement.
- `lib/test/lint-skills-glob-guard.py`, a narrow marker-aware check that fails the suite when a fenced shell block under `skills/` expands an unguarded filename pattern. It recognises one high-confidence shape and is discharged by the `setopt nonomatch` guard or a `# glob-ok: <reason>` declaration marker.
