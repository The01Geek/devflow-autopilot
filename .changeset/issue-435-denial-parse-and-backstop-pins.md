---
bump: patch
type: Fixed
---

- **Denial-count summary parse is line-bound and validated; two stall-backstop guards gain behavioral pins.** `build-experiment-records.py`'s `permission_denials_count:` reader now captures its token only from the label's own line (the old `\s*(\S+)` regex could span a newline and fabricate a count from the next line) and accepts only valid tokens — all-digit strings or the literal `unavailable`; `_resolve_denials` is restructured into two phases (every probed sha's summaries scanned for the first valid token, then a `fetch-failed` → `unparseable` → annotation-fallback → `absent` precedence), so a malformed summary now resolves to `(None, "unparseable")` instead of a fabricated value. Adds `lib/test/run.sh` coverage that behaviorally drives the mktemp-failure arm of `scripts/post-review-backstop-comment.sh` and mutation-proof-pins `devflow.yml`'s manual-path `HEAD_SHA="$HEAD_SHA" bash "$HELPER"` prefix. (#435)
