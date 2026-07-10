---
bump: patch
type: Added
---

- **Matcher-probe workflow for permission-shape evidence.** New
  `.github/workflows/matcher-probe.yml` empirically measures which command *shapes*
  the deployed `anthropics/claude-code-action@v1` permission matcher accepts under
  the read-only `review` tool profile — the silent shape denials (leading `cd`,
  leading `VAR=` assignments, heredoc writes, the unexpanded
  `"${CLAUDE_SKILL_DIR:-…}"` anchor form) that burn a cloud review run to a
  no-verdict stall (issue #401, evidence run 29105381021 on PR #397). One Haiku
  `claude-code-action` session runs the review profile plus the candidate grants
  under test (`Bash(cd:*)`, `Write(/tmp/**)`, `Write(.devflow/tmp/**)`) over an
  11-shape corpus; a post-action step computes a per-shape PERMITTED/DENIED/
  UNATTEMPTED table deterministically from the execution file's
  `permission_denials` plus recorded `tool_use` inputs and on-disk side-effect
  files — never the model's text output. Triggered by `workflow_dispatch` and by
  `pull_request` scoped to the workflow's own path, same-repo only, and
  concurrency-capped. Part of #401.
- **Probe-gated review-profile grant.** Keyed to the probe's first run
  (29111394360): the `review` profile in `.github/workflows/devflow-runner.yml`
  gains `Write(.devflow/tmp/**)` (row 9 PERMITTED — the reviewer authors
  workpad/scratch into the gitignored `.devflow/tmp` via the Write tool, never a
  shell `>` redirect, which the probe recorded DENIED). The other two candidates
  are DROPPED on the evidence: `Write(/tmp/**)` (row 8 DENIED — out-of-workspace)
  and `Bash(cd:*)` (row 3 DENIED, confounded by an independently-denied `>`
  redirect, so unproven pending a redirect-free re-probe). The repo tree stays
  read-only — the reviewer's `contents: read` token still makes a push impossible.
