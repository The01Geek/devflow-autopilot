---
bump: patch
type: Added
---

- **Plain-language `Devflow Review` deferral title for a run awaiting CI approval.** `devflow-review.yml`'s `create_check` title `case` now maps the `ci-approval-required` reason (shipped in #351) to the neutral check title **"Devflow review waiting: CI approval required"** instead of the generic "precondition not met" fallback, so an operator sees the exact unblock action. The deferral `SUMMARY` prose no longer cites "a cancelled sibling run" as a permanently-stuck signal requiring a manual Re-run, since the #351 collapse now auto-resolves the superseded cancelled-sibling case. Lands the coupled workflow-side half of #351 (held out because a GitHub App token cannot push `.github/workflows/`). (#359)
