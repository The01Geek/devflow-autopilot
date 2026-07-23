---
bump: patch
type: Added
---

- **Surface a missing `Verification evidence:` marker as a tier-scoped advisory review finding.** The
  shared review engine gains a non-blocking advisory clause (byte-identical in
  `.devflow/prompt-extensions/review.md` and `review-and-fix.md`) that classifies each PR by tier from
  the workpad `## Progress` `<!-- devflow:checkpoint gha:… -->` rows and, on a local/interactive PR that
  claims completion with the `Verification evidence:` marker absent from both the workpad and the PR
  description, emits one advisory finding — never raising the verdict on its own. It is silent on
  cloud-classified PRs and on local PRs whose marker is present. `lib/cheap-gate.jq` records why it stays
  unwired to the marker (its input population is merged, predominantly-cloud watched-author PRs). (#747)
