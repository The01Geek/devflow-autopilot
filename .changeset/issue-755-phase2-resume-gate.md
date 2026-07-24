---
bump: patch
type: Added
---

- **Phase 2 resume-idempotency gate for auto-resumed `/devflow:implement` runs.** A stalled cloud run that `devflow_implement.stall_backstop` auto-resumes no longer re-dispatches the Phase 2 `code-explorer`/`code-architect` subagents from scratch. A new §2.0 gate at Phase 2 entry fires only when both (a) Phase 1.3 recorded a durable `resume-kind: in-flight` marker and (b) a committed non-placeholder `## Plan` is present, then skips the discovery/architecture re-dispatch and builds on the committed Plan and the §1.4-adopted branch — still running §2.2.5/§2.2.6 idempotently and re-verifying against a fresh tree, and adopting the already-open PR at §3.1 rather than erroring. This makes auto-resume cheaper and faithful to already-shipped work. (#755)
