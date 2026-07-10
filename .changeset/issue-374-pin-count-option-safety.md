---
bump: patch
type: Changed
---

- **The `lib/test/run.sh` pin-helper family is now option-safe for flag-shaped literals.**
  `pin_count`, `grep_present`, and `assert_pin_red_on_removal` all pass their caller literal to
  `grep -F` after an explicit `--`, so a literal beginning with `-`/`--` (e.g. a `--tick-progress`
  pin) is treated as the search pattern rather than parsed as grep options and silently
  mis-counted as absent (0). This makes `pin_count` — and therefore `assert_pin_unique` — safe
  for flag-shaped pins that previously required a hand-guarded raw `grep -qF --` at the call site.
  (#374)
- **The mutation-check discipline is now copy-based, never destructive.** At both coupled sites
  (`skills/review-and-fix/SKILL.md` Step 3 and `skills/implement/phases/phase-2-implement.md`), a
  guard's vacuity is proven by breaking what it pins *on a copy of the file* and confirming it
  goes RED there — never by an in-place "break then restore" that a crash or interruption could
  leave broken. (#374)
