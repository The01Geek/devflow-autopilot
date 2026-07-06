---
bump: patch
type: Fixed
---

- **`workpad.py update --rewrite-ac` is now repeatable.** Previously the flag was declared
  `nargs=2` with no `action='append'`, so a single `update` call carrying two `--rewrite-ac`
  pairs silently kept only the last pair and still exited 0 — violating the helper's
  documented all-or-nothing structural-mutation contract. The flag now uses
  `action='append'`, applying every pair in argument order; each is validated by the existing
  exactly-one-match rule, and any pair matching zero or multiple rows aborts the whole call
  with no PATCH. (#316)
