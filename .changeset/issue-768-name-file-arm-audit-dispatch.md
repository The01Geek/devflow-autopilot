---
bump: patch
type: Changed
---

- **Named the file-arm audit dispatch path in the `create-issue` Step 3.6 procedure.** The
  instruction-generation paragraph now names a shell redirect as the write transport (the
  redirect truncates the target before the generator runs, so no delete-first step remains),
  defines the landed check as an exit-zero generator plus a non-empty file, and names a
  `python3`-headed extraction of the `dispatch-pointer:` line — never `grep`/`sed`/`awk`,
  since that line becomes the entire Agent-tool prompt. The `record-dispatch` output
  description now names `round=`, `arm=`, and `dispatch_regeneration=`, directing the
  orchestrator to surface a `diverged` value in chat at the dispatch site. The dispatch
  barrier is stated behaviorally with `run_in_background: false` as a dated example, and the
  no-fallback-wakeup rule and the instruction file's lifetime are stated. Skill prose only —
  no helper behavior changes. (#768)
