---
bump: patch
---

Add `scripts/checkout-fingerprint.py`, the single producer of the five-field checkout fingerprint the verification-flight ledger keys on, and close the fingerprint fail-open (#1243). `_validate_checkout` now requires the four content fields to be git object ids (rejecting invented placeholders like `"v"`/`"clean"`), and `verification-flight.py status`/`wait` enforce the state-pass **and** checkout-verified condition themselves — a read that could not verify the working tree no longer reports `satisfies_verification: true` or exits 0, with an explicit `--allow-unverified-checkout` opt-out for the weaker read. The unused `verification_flight.profiles` config namespace is removed.
