---
bump: patch
type: Changed
---

- **State focused-first as a precondition on the mid-iteration full-suite launch, and mandate a single-turn push/verify co-issue.** The prompt extensions now bind every touched surface that has a covering focused test invocable on the tier to run before a mid-iteration full-suite launch (with a total four-ground exempt set governing the rest), and require the CI-triggering push and the local verification run to be issued in a single assistant turn. The review-and-fix reference now states how a suite result is established — from the runner's terminal summary line, never from an unread process or wrapper exit status — and the in-env review arm and Phase 4 docs pass are reconciled to it. (#1192)
