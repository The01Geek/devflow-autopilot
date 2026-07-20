---
bump: patch
type: Added
---

- **`/devflow:review-and-fix` records a formal `reference_reads.fix_delta` evidence field, and the
  run-scoped evidence schema is reconciled across every surface that defines it.** `sweep_defs_read`
  and `sweep_evidence` were mandated by the authoritative `iter-<N>.json` writer but missing from the
  root `### Schema` block and from `ITER_EXPECTED_FIELDS`; they are now stated in both, so the
  single-source field set and the schema finally agree. On top of that reconciled base, Step 3.5's
  fix-delta gate now persists its outcome durably in a conditional `reference_reads` field — the
  formal record for a behavior that previously shipped with no schema — carrying `verified` /
  `not_verified` with the two failure arms' distinct breadcrumbs preserved in `reason`. (#625)

- **Fix-commit-only synthesized records no longer serialize absent evidence as real evidence.** When
  a run leaves no per-iteration workpad, the synthesis floor reconstructs a record from the fix
  commits — which carry no trace of which sweeps ran or whether the fix-delta gate ran. That evidence
  is now stamped `{"status": "unrecoverable", "reason": …}` instead of the plausible-looking `[]` and
  `{"status": "not-run"}`, which are the *legitimate* values of a real no-fix iteration and would
  otherwise assert something about an iteration the floor never observed. `--self-check` validates
  both the presence and the `unrecoverable` shape of that provenance, so a synthesizer that stopped
  stamping it — or that regressed to a real-looking `[]` / `not-run` — emits a warning instead of
  validating in silence. (`--self-check` is warn-only by contract: it never writes and never fails
  the run; the `lib/test/run.sh` assertions are what turn the same regression RED at the desk.) (#625)
