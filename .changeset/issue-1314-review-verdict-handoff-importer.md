---
bump: patch
type: Added
---

- **Add the strict review-verdict handoff importer (`scripts/import-review-verdict-handoff.py`).** This is the security-critical validation core of the trusted cloud-review-emitter design (issue #1314, Part 1): it validates the small producer-written handoff as untrusted input — opening with `O_NOFOLLOW`, rejecting non-regular files, extra hard links, oversized data, invalid UTF-8, NUL bytes, disallowed control characters, unstable metadata, unknown fields, and any handoff outside the closed `schema_version:1` / `complete:true` schema or the three legal review-event/marker-verdict pairs — and publishes a normalized artifact only after every check passes, so no write-capable emitter work is ever scheduled on bad input. The producer/emitter workflow wiring is tracked in follow-up work. (#1314)
