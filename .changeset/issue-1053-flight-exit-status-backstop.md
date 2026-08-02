---
bump: patch
---

Refuse a verification-flight `passed` without a zero exit status (#1053).

`verification-flight.py`'s `finish` gate previously tested only that the terminal
summary was a non-empty object, so the ledger minted a `passed` handle that
`check-completion-evidence.py`'s already-shipped implement-completion contract
(#1087) would later refuse — a run banked a pass and discovered it at the phase
where the work was already finished. `finish --result passed` now additionally
requires a JSON integer `0` `exit_status` in that summary; a missing, boolean,
string, float, or nonzero value is refused. The refusal is **non-terminal**: it
writes no state, so the flight stays `running` and re-finishable and the truthful
`finish --result failed` can still be recorded — a terminal write here would
permanently strand that failure, the ledger being one-shot per key. Its output
carries an attributable reason (`exit_status_unestablished` vs
`exit_status_nonzero`), the recorded value, and the owner-token retention the
re-issue needs. `failed`/`timed_out`/`cancelled` are ungated, and the existing
missing-or-unusable-summary arm runs first and keeps its terminal `incomplete`
disposition unchanged. The reuse predicate gains the same exit-status limb so a
handle written before this change — a `passed` state with no `exit_status` — is
disposed of as not reusable, matching what the completion gate already does,
rather than directing an attacher to consume a pass that gate refuses.

The backstop **narrows** the false-green path rather than closing it: the ledger
executes nothing and observes nothing, so it catches a caller holding a truthful
nonzero status that still claims a pass, and not one that writes a zero it never
observed.
