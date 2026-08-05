---
bump: patch
type: Fixed
---

- **`scripts/dedupe-review-command.sh` now ships executable (`100755`).** It was tracked
  `100644`, so both `[ ! -x … ]` guards in `.github/workflows/devflow.yml` were true on every
  run and Candidate-C in-flight-review dedupe — and its suppression notice — never fired since
  the feature landed. A new suite check, `lib/test/lint-executable-helper-mode.py`, derives the
  `-x`-gated bundled-helper set mechanically (joining `VAR=<path>` assignments to `[ -x "$VAR" ]`
  tests across the tracked workflows and `scripts/*.sh` / `lib/*.sh`) and fails RED if a resolved
  repo helper is not tracked `100755`, so a lost executable bit is caught at the desk instead of
  failing open in production. (#1312)
