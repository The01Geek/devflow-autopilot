---
bump: patch
---

### Fixed

- `/devflow:implement` now screens the ahead-of-base branch state on the **landed-resume** arm, closing the residual issue #779 disclosed. Verdict B (`scripts/preflight.py branch-state`, `phase-1-setup.md` §1.4.0.5) previously ran on the adopted-branch arm only, so a resumed run merged and pushed a branch whose ahead history had never been screened for the PR #524 foreign-commit shape.
- The classifier now accepts a second provenance source alongside the workpad: the **open-PR linkage** — an open PR in this repository whose head branch is the working branch, which closes this issue, and which is not cross-repository. Without it, widening Verdict B would have turned two large populations of ordinarily-resumable runs into terminal `Blocked` stops: a cloud run whose Phase 1.3 `HANDOFF` record is `unknown`, and a local resumed run that did not create its own workpad. On the PR-vouched path the untrusted workpad is neutralized rather than consulted, every conjunct fails closed (an ungathered cross-repository field included), and the two new gate booleans join the existing quoted-string refusal.
