---
bump: patch
type: Added
---

- **`/devflow:implement` now survives a nested skill's return and resumes onto an existing PR.**
  A Skill-tool invocation is a tail call, not a subroutine call: when a nested skill's procedure
  ended in a user-facing approval step, the implement run ended with it — the workpad froze at an
  in-progress `Status`, no terminal reaction fired, and the run died silently. Four orchestrator
  rules close that gap. A **generalized mid-phase re-anchor** makes the orchestrator re-read the
  current phase file after *every* Skill-tool return and resume at the step that follows it (the
  Phase 4.1 docs-subagent re-anchor remains, now scoped to *subagent* returns). A
  **non-interactive self-answer rule** has a cloud-tier run answer a nested skill's user-facing
  question itself — from the issue description, recorded in the workpad — instead of stranding on
  a question no one can answer, while an interactive run still asks the user. A **subagent-dispatch
  rule** routes any edit that project conventions send through an *interactive* skill (one whose
  procedure ends in a user approval step) into a context-isolated Agent-tool subagent whose prompt
  pre-grants the approval, rather than invoking it mid-phase. And a **Phase 1.4 resume pre-check**
  now consults the workpad `Branch` line and the issue's open PRs *before* the linked-worktree
  signal, so a re-triggered run continues the existing branch and draft PR instead of forking a
  duplicate and abandoning committed work. (#364)
- **New local-tier Stop-hook backstop, `lib/implement-stop-guard.sh`.** Phase 1.3 writes a
  gitignored run marker under `.devflow/tmp/`, and the guard — wired as a second `Stop` hook —
  blocks a session's stop (exit 2) while that issue's workpad `Status` is still interim, naming the
  issue and the status word so the run returns and finalizes. It is bounded to at most one block
  per session, fails open on every ambiguous path (unreadable workpad, `gh` transport failure,
  unparseable hook input), performs **no** network call when no marker is present, and self-heals a
  stale marker. The marker is removed at every terminal `Status` transition. Consumer repos are
  unaffected: the hook is repo-local, and the cloud tier keeps its existing workflow-level stall
  backstop. (#364)
