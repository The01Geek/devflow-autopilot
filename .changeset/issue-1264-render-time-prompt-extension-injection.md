---
bump: patch
---

### Fixed

- The consumer prompt extension is now delivered to the `/prflow:review`,
  `/prflow:review-and-fix` and `/prflow:implement` skills by **render-time injection**
  rather than by a command the agent chooses to run, so repository policy is applied
  deterministically instead of intermittently. Measured before the change: the extension
  reached the agent in only 8 of 18 sampled review runs and 1 of 4 sampled implement
  runs, and both failure modes were silent — a review that never loaded the policy still
  posted a normal APPROVE/REJECT verdict, and nothing in the verdict, the workflow or CI
  distinguished it from one that had. Two pull requests reviewed three minutes apart
  received opposite treatment on the same gate for this reason.

### Added

- `scripts/render-prompt-extension.sh`, the wrapper behind the new placeholder. It
  **always exits 0** and always writes one `PROMPT-EXTENSION-STATUS:` line —
  `content-present`, `present-empty`, or `unestablished (<reason>)` — so the rendered
  skill body carries a positive statement of what happened rather than an absence to be
  inferred from. Always exiting 0 is load-bearing rather than defensive: a non-zero exit
  from an injected command aborts the whole skill invocation at zero turns, and
  `load-prompt-extension.sh` exits 2 on every present-but-undeliverable shape, which is
  an ordinary thing for a consumer tree to contain. Wired naively, that would have turned
  a benign no-op into a silent no-verdict run at the merge gate.
- `unestablished` is never collapsed onto `present-empty`. An absent trusted closure — a
  `DEVFLOW_PROMPT_EXTENSION_ROOT` naming a directory that does not exist — is reported as
  unestablished, where the underlying reader alone would have reported it as an ordinary
  absent extension and a policy-free review would have read as a clean policy pass.

### Changed

- The existing loader prose in all three skills is demoted to an explicit fallback that
  applies only on runners without render-time preprocessing (Copilot CLI, Cursor, Codex
  CLI, Gemini CLI); the portable anchor form is preserved unchanged for them.
- `Bash(*/render-prompt-extension.sh:*)` and its vendored literal are granted on the
  `review`, `implement` and `command` profiles. This widens the read-only reviewer
  profile, so `lib/review-profile.tokens` is updated in the same change.
