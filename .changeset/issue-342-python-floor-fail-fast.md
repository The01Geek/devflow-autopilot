---
bump: patch
type: Fixed
---

- **`workpad.py` and `match-deferrals.py` now fail fast with an actionable `Python 3.11+ required` error on pre-3.11 interpreters.** Both helpers annotate functions with PEP 604 unions (`str | None`), which any interpreter older than 3.10 evaluates at definition time and dies on with a raw `TypeError` traceback naming neither the cause nor the remedy. Each helper now carries a `sys.version_info < (3, 11)` gate immediately after its import block — before any annotation is evaluated — that prints one plain-ASCII stderr line naming the running version, the `Python 3.11+ required` floor, and the `scripts/provision-python3-shim.sh` / `docs/install.md` remedy, then exits 1. On Python 3.11+ (the declared floor, unchanged) behavior is identical. Also corrects the stale `config.schema.json` and `CLAUDE.md` claims that `workpad.py` needs PyYAML — it is stdlib-only; the lazy-yaml helpers are `match-deferrals.py` and `consolidate-changesets.py`. (#343)
