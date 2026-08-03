---
bump: patch
---

Record the owning session in the implement liveness marker so the local Stop-hook guard no longer blocks unrelated sessions in the same checkout.

The `/prflow:implement` run marker (`.prflow/tmp/implement-active-<issue>`) now records the runner's session id as its first line when one is supplied (Claude Code's `CLAUDE_CODE_SESSION_ID`, byte-identical to the Stop payload's `session_id`), and stays empty otherwise. `lib/implement-stop-guard.sh` reads that first line: an interim marker owned by a *different* live session no longer blocks the stopping session — it prints an issue+status breadcrumb (so the "a run may be stuck" signal survives), writes no sentinel, and keeps scanning. Ownership is compared like with like, so every absent, blank, malformed, or unreadable owner — including every zero-byte marker written before this change — fails closed and blocks exactly as before. Self-heal of terminal or workpad-less markers is unchanged and applies regardless of owner.
