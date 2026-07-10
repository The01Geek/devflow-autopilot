---
bump: patch
type: Fixed
---

- **Review live-comment seeding no longer misreads an interpreter-level exit 2 as "first write."** `skills/review/SKILL.md` branched its live progress-comment seed on `workpad.py id`'s exit code, treating rc 2 as `cmd_id`'s clean-absence "first write". But `python3` also exits 2 when it cannot open the script (`[Errno 2]`/`[Errno 13]` on a partial or unreadable vendor copy) and `argparse` exits 2 on a non-numeric PR number, so an interpreter-level failure was misdiagnosed as "create" and its captured stderr discarded. Three coupled screens now keep the "first write" arm reachable only from `cmd_id`'s own silent `sys.exit(2)`: a non-numeric-PR-number guard before the `id` call, a readable-path precheck on `workpad.py` before exec (with a distinct missing/unreadable breadcrumb), and an empty-captured-stderr requirement on the rc-2 arm; the failure arm now surfaces the captured stderr instead of swallowing it. (#388)
