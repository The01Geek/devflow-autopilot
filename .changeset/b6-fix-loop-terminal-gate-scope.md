---
bump: patch
type: Changed
---

- **The fix loop's terminal whole-suite gate is scoped to what actually verifies the tree.**
  The loop's terminal verdict is a findings verdict, and the honesty floor it genuinely owes
  is an in-env run over the surfaces it changed — now stated as non-negotiable on every tier
  and for every caller. The whole-suite obligation on top of that floor is narrowed on both
  sides. Inside `/prflow:implement` (Phase 3.3) it is dropped: every Phase 4 commit makes a
  Phase 3 flight stale by definition and Phase 4.3's completion-evidence flight re-verifies
  the final tree anyway, so the obligation is owned exactly once, by that flight, whose terms
  and `#456` skip accounting are unchanged. At a standalone terminal it survives only where
  the run establishes that no backstop outside it will exercise the broader suite over this
  tree — the ordinary case, since the loop reviews the current branch when given no PR number
  and `--push-each-iteration` is off by default. Where a standalone run does publish to a PR
  whose merge the project gates on such a check, the loop emits its findings verdict without
  a whole-suite pass and may not assert that the broader suite is green. A loop that cannot
  establish either predicate takes the whole-suite result. The issue-#405 in-env rule is
  untouched: this scopes which run pays the pass and what the terminal may claim, never which
  channel establishes either, and introduces no CI wait, poll, re-check, or citation.
