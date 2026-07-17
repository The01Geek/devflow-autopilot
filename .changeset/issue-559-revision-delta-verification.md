---
bump: patch
type: Added
---

- **`/devflow:create-issue` now verifies the content a revision itself introduces.** A new
  shared **Revision-delta verification** procedure is stated once in `skills/create-issue/SKILL.md`
  and referenced by every revise-and-re-gate site (Step 3.5's items 5 and 6, Step 3.6's `VERDICT:
  REVISE` handling and its user-chosen rounds, and Step 4 sub-step 4's two revision sentences).
  At every revision event it walks the edit-batch delta across six classes (mechanisms, lifecycle
  rules, execution-tier assumptions, dependencies, universal guarantees, and a total-making
  residual class), verifies each non-empty class against the code via the two existing Step 3.5
  disciplines, fixes findings inline, and closes with a per-site evidence line — so audit rounds
  are spent on genuinely fresh defects and a revision reaching filing on a declined re-audit has
  had its delta walked and verified rather than only language-gated. A persistent `lib/test/run.sh`
  coverage guard classifies every `no-options gate` occurrence into wired-site / definition-block /
  allowlist bins and turns RED on any unwired revise sentence or an empty wired-site set. (#559)
