---
bump: patch
type: Added
---

- **`/devflow:implement` Phase 1 now defers workflow-resident acceptance criteria at plan time.** The Phase 1.6 issue-claim audit gains an execution-capability pass (Pass 5): on a cloud-tier run, an acceptance criterion that requires editing the repo's own `.github/workflows/` — which the DevFlow bot installation token cannot push — is routed through the Phase 2.2.5 scope-adjustment before any code is written, deferred to a follow-up issue that states it needs a human/PAT (workflows-scoped) push, instead of being discovered at push time after a full commit is built. A file coupled to a blocked workflow edit (a `lib/test/run.sh` pin that turns CI red without the workflow change) is deferred with it, and an issue whose every in-scope criterion is workflow-resident is declined up front rather than producing an empty-handed run. Local/interactive-tier runs, which push workflow files routinely, are unchanged. (#350)
