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
- **Its `REGISTRATION` and `TRUST BOUNDARY` paragraphs no longer rest on a false premise
  either.** Both still said nothing in the tree registers the guard and that
  `devflow-runner.yml` passes no `settings` input — but that workflow does register a
  `PreToolUse`/`Bash` hook execing this guard, so a reader checking the evidence would find
  it false and could conclude the guard is live. The conclusion survives and the reasoning
  is now the real one: the registration is shipped but unreachable in this repository,
  because `devflow-runner.yml` declares `workflow_call` as its only trigger and its sole
  caller was the auto-review tier withheld under issue #936 — explicitly not dead code,
  since a consumer that installed that tier before it was withheld still has the caller
  this tree lacks. `TRUST BOUNDARY` likewise no longer claims both registration channels
  must land together: issue #908 closed that hole from the other side, with a dedicated
  unconditional harden step for the guard's import closure.
- Comment-only throughout: the guard's executable body is byte-identical, checked by
  comparing the module AST with its docstring removed.
