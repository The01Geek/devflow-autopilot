---
bump: patch
type: Added
---

- **Opt-in `--strict` exit-code mode for the pin-corpus and command-head scanners.**
  `lib/test/pin-corpus-lint.py` (its `lint` and `wrapped` subcommands) and
  `lib/test/extract-command-heads.py` (its `ungranted` subcommand) now accept a
  `--strict` flag: a run that writes at least one finding line to stdout exits `3`,
  and one that writes none exits `0`, so a suite author can key an assertion on the
  exit code instead of folding rc and stdout by hand. Without the flag both tools
  behave byte-for-byte as before, so every existing call site is unaffected. Every
  stdout write on a covered path routes through a single emit helper, and
  `lib/test/run.sh` gained region-anchored guards that keep it that way; `heads`
  rejects `--strict` because its stdout is a data product. (#694)
