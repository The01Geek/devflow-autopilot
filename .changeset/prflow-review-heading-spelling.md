---
bump: patch
---

### Changed

- The review engine now names itself **PRFlow Review** in the output a human reads: the live progress comment's H1 template and the verdict stub's pointer sentence. The `Devflow Review` check-run and workflow names are deliberately unchanged — they are a required status check matched by exact string in branch protection rules and rulesets, so renaming them would wedge every consumer's merge gate.

### Fixed

- The Phase 0.3.6 blocker-recheck precondition now recognises a prior REJECT whose body carries either the current `PRFlow Review` heading or the superseded `Devflow Review` spelling, resolved per review. Reviews already posted on long-lived pull requests are immutable and carry the old spelling, so a consumer that accepted only the new one would silently stop recognising its own review history.
