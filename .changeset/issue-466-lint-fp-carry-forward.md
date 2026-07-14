---
bump: minor
type: Added
---

- **Carry adjudicated stale-prose-lint false positives across review runs.** The review engine
  now remembers when a run's Phase 4 triage verified a Phase 0.6 STALE stale-prose row as a false
  positive: it renders the finding Informational with the concrete referent evidence and stamps a
  hidden, base64-encoded adjudication payload inside a sentinel-delimited section of the run's
  `devflow:review-progress` comment. Every later run's Phase 0.6, before finalizing STALE rows as
  findings, joins the current rows against those payloads via the new deterministic, network-free
  helper `scripts/match-lint-adjudications.py` and demotes a byte-identical `(rule, path, detail)`
  match to Informational — annotated with the adjudicating run key and excluded from verdict
  computation. Carry-forward is scoped to the rules whose detail embeds the observed referent
  (`R1`/`R2`/`R3`), so an edit to the counted code invalidates the match; `R4` (modality conflict)
  is excluded — its detail describes only the claim line, so a stale adjudication would otherwise
  keep matching after a later commit added a genuine contradicting permit. The join is
  trust-guarded (run-keyed marker plus a Bot-type/`allowed_bots` author),
  PR-scoped by construction, ambiguity-safe (a colliding key never demotes), and degrades loudly
  (an absent/refused/erroring helper leaves every STALE row at its configured severity with a
  degraded-check note). Operators stop paying an extra review-fix iteration per recurring lint
  false positive. (#466)
- **Config-derivation shape-matrix rule for reception fixes (DevFlow-repo policy).** The
  `receiving-code-review` and `review-and-fix` prompt extensions now require any fix that touches
  how a config value is read, derived, or defaulted to sweep the full six-shape adversarial matrix
  — `{object, array, scalar, valid-falsy (explicit false / 0 / empty string), missing, wrong-type}`
  — over that value in the same change, each row tested in `lib/test/run.sh`, so a fix no longer
  ships the reviewer-cited row alone and leaves the sibling row for the next run to raise. (#466)
