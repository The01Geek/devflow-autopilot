---
bump: patch
---

Add a behavioral eval (`scripts/create-issue-context-eval.py`) that measures the
runtime main-thread context cost of `/devflow:create-issue` runs from a transcript
corpus, plus a determination doc (`docs/create-issue-context.md`) classifying which
appended-content classes are authoritative versus safely-removable redundant
additions. The create-issue skill now references already-resident/durable content by
pointer instead of re-quoting it (removing the primary safely-removable re-emission),
with no audit, evidence, decision, draft-identity, or state-machine guarantee weakened.
The eval is maintainer-run and never on the skill's runtime path, so it adds no new
cloud tool grant and no static word-count gate.
