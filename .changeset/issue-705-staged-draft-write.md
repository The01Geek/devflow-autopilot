---
bump: patch
type: Added
---

- **`/devflow:create-issue` canonical-draft writes are now durable.** A new bundled helper
  `scripts/stage-draft-write.py` (stage/emit/apply modes) stages the intended title-and-body
  bytes to a nonce-keyed artifact, replaces the canonical draft in one atomic `os.replace`, and
  re-digests the result to prove the replace landed. A single shared *Staged canonical-draft
  write* procedure, referenced from every write site, records a revision's `stdin_digest`,
  records a `record-write-failure` on disagreement, and runs a cross-turn landed re-check — so
  an interruption after the first staging write is recoverable and a partially-applied revision
  wave is a detectable state instead of a silent divergence. `issue-audit-state.py record-revision`
  now refuses a file-arm-latest-round revision that carries no `--stdin-digest`, so the
  write-failure closure shipped in #562 is enforced by the tool and reachable from the skill for
  the first time. (#705)
