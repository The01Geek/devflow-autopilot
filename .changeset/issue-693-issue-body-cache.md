---
bump: patch
type: Changed
---

- **Cache the GitHub issue body once per `/devflow:implement` run.** Phase 1 §1.1 now fetches the
  issue body a single time per run attempt into an in-tree cache
  (`.devflow/tmp/issue-body/issue-<n>.md`) and hands it to the Phase 1–2 consumers by path — shell
  helpers through their `--body-file` arms, the `code-explorer`, `code-architect`, and `devflow:docs`
  subagent dispatches through an `Issue body path:` line instead of an inline paste. Reads are
  hand-off-only and every verdict-bearing reader (the Documentation-Needed gate, the inline review's
  issue-compliance check, `/pr-description`, `receiving-code-review`) keeps fetching live. A new
  `lib/test/lint-issue-body-refetch.py` scanner turns the suite RED if a cut-over site re-fetches the
  body. (#693)
