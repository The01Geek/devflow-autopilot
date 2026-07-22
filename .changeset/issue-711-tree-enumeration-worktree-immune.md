---
bump: patch
---

### Fixed

- The test suite's `only one committed prompt-mass baseline exists` check now counts baselines
  from the git index (`git ls-files`) instead of walking the filesystem from the repository root.
  The old walk descended into every sibling git worktree under `.claude/worktrees/` and counted
  their copies, so the check failed on any working checkout that carried worktrees — with a
  number that varied between runs on the same commit — while CI's fresh checkout stayed green.
  Unknown is never collapsed onto zero: an unavailable `git` reports `git-unavailable` and an
  empty-but-successful population reports `no-committed-baseline`, never a count of `0`.
- `lib/test/lint-gh-api-repo-path.py` now carries its own `.claude/worktrees/` exclusion. Its
  population is a working-tree enumeration, which was worktree-immune only through an untracked
  `.git/info/exclude` line that no clone inherits, so on a bare clone it could report violations
  living in another branch's checkout.

### Added

- `lib/test/lint-tree-enumeration.py`, a desk-time guard that turns the suite red when a tracked
  `.py` or `.sh` file under `lib/test/` enumerates with a recursive walk carrying no
  `# tree-walk-ok: <reason>` declaration. It does not bar a walk — it makes one a reviewable,
  greppable declaration, joining `# raw-guard-ok:` and `# structural-pin-ok:` as the third member
  of the repository's declaration-marker family. Its scanner reads a `#` as a comment only at a
  word boundary (so a `${var#...}` parameter expansion no longer hides the rest of its line) and
  accepts the declaration marker only from a line's comment (so marker text inside a string
  literal cannot exempt a real walk); its shell arm tests every path operand rather than a
  computed first one (so an option taking a separated value no longer hides the root operand), and
  locates the command head through the shared `extract-command-heads.py` classification instead of
  assuming leading position (so a walk behind `LC_ALL=C`, `xargs`, `timeout`, a redirection, `!`,
  or an `if`/`while` condition is reached, as is one inside a `<(…)` process substitution). Each
  was a fail-open the guard reported clean over, and each is retained as a suite fixture.
