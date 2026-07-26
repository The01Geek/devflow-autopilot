---
bump: patch
---

### Fixed

- `/devflow:implement` now screens the ahead-of-base branch state on the **landed-resume** arm, closing the residual issue #779 disclosed. Verdict B (`scripts/preflight.py branch-state`, `phase-1-setup.md` §1.4.0.5) previously ran on the adopted-branch arm only, so a resumed run merged and pushed a branch whose ahead history had never been screened for the PR #524 foreign-commit shape.
- The classifier now accepts a second provenance source alongside the workpad: the **open-PR linkage** — an open PR in this repository whose head branch is the working branch, which is not cross-repository, and which is tied to this issue either by closing it or by having been selected by the Phase 1.4 resume pre-check's head-branch query. Without it, widening Verdict B would have turned two large populations of ordinarily-resumable runs into terminal `Blocked` stops: a cloud run whose Phase 1.3 `HANDOFF` record is `unknown`, and a local resumed run that did not create its own workpad. On the PR-vouched path the untrusted workpad is neutralized rather than consulted; the workpad takes precedence wherever the sources overlap, so a workpad-vouched run classifies exactly as before; every conjunct fails closed; a *partial* gather of the PR operands is refused by name rather than read as a refutation the caller never established; and the new gate operands join the existing quoted-string refusal so a mis-encoded value names itself instead of masquerading as a real refutation.
