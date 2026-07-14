---
bump: patch
type: Added
---

- **Keep writer-job push and gh credentials fresh past the App token's 60-minute lifetime.**
  A GitHub App installation token expires one hour after minting and cannot be renewed, so a
  `/devflow:implement` or `/devflow:review-and-fix` cloud run that outlives that hour used to
  spend its remainder fighting dead credentials (`git push` and agent-side `gh` both 401). Both
  writer jobs now start a detached background credential refresher (`scripts/refresh-app-credentials.sh`,
  45-minute cadence with a 2-minute backoff) that re-mints a fresh installation token and rewrites
  the checkout-persisted `http.<server>/.extraheader` credential and a mode-0600 token file in
  place; a `gh` wrapper (`scripts/gh-fresh.sh`, installed as `DEVFLOW_GH` and ahead of `gh` on
  `PATH`) resolves the token at call time, discriminating the ambient job-start token from a
  deliberately-fresh `#287` backstop mint by fingerprint. A two-strikes bad-credential fail-fast
  rule stops long runs from burning budget on dead credentials. With no App configured
  (`vars.DEVFLOW_APP_ID` empty) everything is a no-op, byte-identical to today. (#487)
