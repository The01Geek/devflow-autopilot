---
bump: patch
type: Added
---

- **Single-flight verification coordination (`scripts/verification-flight.py`).** Implement and inline Review-and-Fix now coordinate each same-checkout full-verification flight through a new non-executing coordination ledger (`claim`/`mark-running`/`finish`, attach/`wait`/consume) instead of relaunching the same unchanged suite within one lifecycle. The helper launches no subprocess and accepts no executable argv — existing callers keep command ownership and allowlist enforcement — and coordinates on a SHA-256 command descriptor plus a full checkout fingerprint (HEAD, index, tracked, untracked). States are `claimed`/`running`/`passed`/`failed`/`timed_out`/`cancelled`/`stale`/`incomplete`; only a `passed` handle with complete matching bindings satisfies verification, and a missing/partial/timed-out/unreadable/stale handle never becomes a pass and never authorizes an automatic relaunch. Adds a versioned `verification_flight` config namespace and grants the vendored helper in `devflow.yml` and `devflow-implement.yml` only (never the read-only reviewer). CI-grounded standalone `/devflow:review` creates no flight. (#528)
