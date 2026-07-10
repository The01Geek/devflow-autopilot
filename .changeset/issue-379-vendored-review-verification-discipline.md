---
bump: patch
type: Added
---

- **Verification discipline in the vendored review skills.** `receiving-code-review` now
  carries a negative-test attribution rule (pin the rejecting guard's own distinct signal
  when more than one guard can reject the input), a positive-control rule (a negative test
  carries a positive control on the same fixture), a mutation-check requirement before any
  completion claim, and a fired-on-writing-a-guard rewrite of *Share the Contract* (name the
  protected downstream operation before writing the predicate; grep for an existing idiom
  first). `requesting-code-review` now requires stating mutation evidence for the tests a
  review request presents. All wording is repo-agnostic so consumer repos inherit it. The
  DevFlow prompt extensions gain two new guard-class shapes (vacuous negative test;
  re-derived consumer contract) and an interpreter-faithful-probe rule, each recording its
  PR #340 reproduction. Discharges #371 R3, R4, and R7. (#398)
