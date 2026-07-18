---
bump: patch
type: Added
---

- **Cloud-writer reachability contract + runtime manifest (AC1 + AC18 of #543).** Add
  `lib/test/cloud_writer_contract.py`, a machine-auditable source of truth for the three
  cloud execution roots (implement / light-command / review) and their transitive skill/phase
  closure, with a `check_closure()` guard that fails when a root or dispatch edge names an
  unclassified reached asset. Generate the checked-in `devflow-cloud-writer-contract-v1`
  runtime manifest from that same closure, and add `scripts/validate-cloud-writer-contract.py`,
  a pre-agent Python 3 validator whose rejection matrix is closed at exactly seventeen classes.
  This is the first, self-contained slice of #533's deferred half; the remaining acceptance
  criteria (call-site rework, profile-shape sweeps, portability/skew/provisioning fixtures,
  grant synchronization) are tracked in follow-up issues. (#543)
