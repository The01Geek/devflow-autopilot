---
bump: patch
---

### Fixed

- The cloud per-agent-effort seam probe no longer reports a run in which nothing was
  measured as evidence against the seam (issue #1177). Both arms of the probe prompt's
  Step 2 run through a model-issued `Bash` echo the top-level model may skip, so a run
  that dispatched the probe subagent and then stopped recorded no marker at all — and
  `scripts/agents-seam-probe-verdict.py` scored it `SEAM_UNPROVEN`, whose rendered text
  tells the reader the seam is unproven. Four of the eight successful recorded dispatches
  had that signature. The verdict vocabulary now separates *measured false* from *not
  measured*: `SEAM_UNPROVEN` requires an affirmative non-forwarding signal (the prompt's
  refusal marker in the record, or a `permission_denials` entry naming the probe
  subagent), and a dispatch that produced neither marker resolves to the new
  `INSTRUMENT_NOT_FIRED`, whose text states that the run is uninformative in either
  direction and says nothing about the seam's status. `SEAM_PROVEN` is unchanged and
  still reachable only through a human `--adjudicated-governed` re-run.

### Added

- Every seam-probe dispatch now prints a verdict-inert diagnostic
  (`dispatch_result_channel` / `forwarded_marker_in_result_channel`) that measures,
  without acting on it, whether the execution record carries a dispatched subagent's
  returned text — the unestablished premise a future "read the marker from the harness
  record" remedy would depend on. It is read by nothing in the verdict computation, so it
  cannot promote a run to `SEAM_FORWARDED` or `SEAM_PROVEN`.
