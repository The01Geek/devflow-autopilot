---
bump: patch
type: Added
---

- **The `receiving-code-review` Reception Preflight now produces machine-checkable session
  artifacts.** Two bundled helpers ship: `scripts/reception_identity.py`, an importable
  stdlib-only routine that derives a content-based **candidate identity** — the git tree object
  ID of the working-tree content (tracked content plus untracked non-ignored files, with
  gitignored content, HEAD, and the index excluded), through a temporary index seeded from the
  current index so the repository's own index is never touched and no history is read; and
  `scripts/reception-record.py`, a CLI whose one `record` invocation derives that identity, mints
  a per-session cryptographic claim-context nonce, and writes an identity artifact, a per-finding
  disposition ledger, and a fixed-name session pointer under the gitignored session directory —
  confirming the directory is ignored (via `git check-ignore`) before writing. The candidate
  identity is commit-invariant across a commit that records exactly the staged content and
  compares unequal for any later tracked-content change. `scripts/verification-flight.py` gains an
  optional top-level `candidate_identity` declaration field recorded in the handle, a sibling of
  `checkout` that leaves `descriptor_digest`, `flight_key`, and `SCHEMA_VERSION` byte-unchanged.
  The Reception Preflight block grows from nine to eleven facts (candidate identity and
  claim-context token); when the helper produces no output both facts render `missing` and the run
  continues, and the editing gate is unchanged. The helper is granted in the `implement` and
  `command` capability profiles only — the read-only reviewer boundary is untouched. (#668)
