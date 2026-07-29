---
bump: patch
type: Fixed
---

- **Close the pin-gate's count-helper bypass.** `mutation-routing-worktree` no longer lets a
  wording-only pin over prose skip prose adjudication by being spelled as `pin_count` /
  `devflow_module_pin_count`: the `count-helper` short-circuit is removed, so a new or modified
  count-helper pin whose literal resolves into prose is reported exactly as the equivalent
  static-helper or raw-`grep` pin, with a finding that names the literal, the prose file and
  line it resolved into, and that the helper does not change the verdict. The pre-existing
  population is grandfathered (only changed sites are adjudicated). (#925)
