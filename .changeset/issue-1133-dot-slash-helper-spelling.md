---
bump: patch
type: Fixed
---

Grant the `./` dot-slash spelling of a bundled-helper invocation on the cloud
implement tier (#1133).

The tool matcher does not normalize a leading `./`, so `./scripts/workpad.py` and
`scripts/workpad.py` are two different literals and a grant of one is not a grant of
the other. A helper the run invoked with a `./` prefix was therefore refused — and a
refusal returns nothing rather than failing, so the run continued while every workpad
write was dropped. On one run that left the workpad frozen at its setup status, which
in turn made the stall backstop decide to resume a run that had already opened a green
pull request.

Every vendored-literal helper token on the `implement` capability profile now carries a
`./`-prefixed alias of the same path, added to `lib/capability-profiles.json`
(`manifest_version` 16 → 17) and compiled into the generated allowlist literals. Under
the working-directory contract both spellings resolve to the same file, so this widens
how an already-granted path may be written and not which helper may run. The `review`
and `command` profiles resolve to byte-identical token lists and
`lib/review-profile.tokens` is unchanged.
