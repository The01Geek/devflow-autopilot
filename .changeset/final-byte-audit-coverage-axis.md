---
bump: patch
---

### Added

- `/devflow:create-issue` Step 3.6 now reports **final-byte audit coverage** as a first-class
  lifecycle fact: whether the bytes that would actually be filed carry a `VERDICT: FILE` from a
  round dispatched against those exact bytes. `query-summary` renders
  `final_byte_coverage=<covered|uncovered|unestablished>` immediately before `bound_root=`, and a
  new `query-final-byte` answers the offer trigger on its own line. Four things never set the
  field to `covered` — a creation attestation, a `cap-reached` override, a `user-decline`
  override, and a clean round whose steering-absence was never established — so a run can no
  longer report `attestation=match` beside unaudited bytes with nothing distinguishing it from an
  auditor-cleared one.
- An **exact-byte safety pass**, offered immediately before the Step 4 approval election when the
  bytes are final and the reported coverage is `uncovered`. It is funded from a dedicated slot
  outside the user-round cap (`record-final-byte-offer`), so a run that legitimately spent every
  discovery round — including the common case of a run that converged on its own self-verified
  fixes — still gets one. The slot is spent per canonical digest, so a revision that changes the
  bytes re-arms it under a per-run cap, and a pass that closes without a verdict refunds it.
  Filing is never blocked: the user's explicit election remains the documented path by which a
  determined filer files, and the summary line now says so.
