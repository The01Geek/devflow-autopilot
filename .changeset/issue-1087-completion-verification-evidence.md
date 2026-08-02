---
bump: patch
---

Require current verification-flight evidence before implement completion (#1087).

The terminal `workpad.py --status Complete` write is now gated on a current,
machine-readable verification-flight record for the run's final in-env
verification command. `check-completion-evidence.py` gains an `implement`
context (importable `validate_implement_completion`) enforcing a strict no-skip
pass contract — terminal `passed` state, a nonempty command, an integer-`0`
exit status, an empty skip population, and a candidate identity equal to the
current tree. `workpad.py update --record-completion-evidence <flight-key>`
records the validated key on the existing keyed-checkpoint marker family, and
the terminal gate re-validates it (re-deriving the candidate identity) before
PATCH; a missing/duplicate marker, non-pass record, or stale identity aborts the
Complete write before any GitHub call. A standalone `workpad.py` copy without the
evidence sibling fails a Complete write closed with `missing-evidence` while its
other subcommands are unaffected. The `verification_flight.enabled` off-switch is
now per-caller: an implement run under `false` still produces the machine record
(reuse bypass), while a standalone review-and-fix run keeps its direct-launch
behavior.
