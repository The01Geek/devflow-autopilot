---
bump: patch
type: Fixed
---

- **`scripts/pretooluse-shape-guard.py`'s `VERDICT PROVENANCE AND EXPIRY` header no longer
  tells a maintainer the harness verdicts cannot be re-established.** That paragraph exists
  to say how the `deny` and `defer` verdicts are re-measured after a `claude-code-action` or
  CLI upgrade expires them, but it still claimed neither probe arm was merged and that
  re-running them "is not actionable from this tree alone" — written before PR #1308 landed
  `defer-probe` and `pretooluse-deny-probe` into `.github/workflows/matcher-probe.yml`. It
  now carries the actual recipe: both triggers that reach those jobs (a bare
  `workflow_dispatch`, and a `pull_request` trigger whose `paths` filter is the workflow's
  own file), and the cost that governs how the recipe should be used — neither trigger can
  select a job, so either fires the whole workflow, most of whose jobs start a paid Claude
  session, which is why a re-probe belongs in one push rather than an iterated sequence.
  Comment-only: the guard's executable body is byte-identical.
