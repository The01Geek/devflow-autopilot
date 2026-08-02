---
bump: patch
type: Fixed
---

- **`/prflow:create-issue` Step 3.6 now names the carriage cause on `record-return` and persists
  the round-kind selecting reason.** `record-return` writes a named stderr breadcrumb — distinct
  for absent vs. mismatched carriage evidence, and distinct from an ordinary unparseable auditor
  return — when a parseable verdict was classified `no-parseable-verdict` because its carriage
  proof was absent or wrong, naming the remedy (supply `--carriage-object-id` with the audited
  draft's object id) while leaving its stdout contract line and exit code byte-identical. Every
  dispatched round now records the reason its kind was selected, beside `kind`, under the unchanged
  schema version and read with a default everywhere (a pre-change round reports its reason as
  unestablished, never a guess); the old shared `no-completed-round` token is split into
  `no-round-dispatched` (the genuine cold first round) and `no-completed-round` (a dispatched round
  that never completed). `record-dispatch` announces the expensive whole-draft path with a stderr
  breadcrumb when it accepts a `discovery` kind selected for a failed-condition reason, and stays
  silent for the genuine first round. `scripts/create-issue-context-eval.py` reads the recorded
  reason alongside the recorded kind in its per-run per-round breakdown. (#1103)
