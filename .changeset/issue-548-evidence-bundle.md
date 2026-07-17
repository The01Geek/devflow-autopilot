---
bump: patch
type: Added
---

- **`/devflow:create-issue` now gates approach recommendations on an axis-complete evidence
  bundle.** The Step 2 independent-derivation pass writes a read-only `## Evidence bundle`
  section into the derivation artifact on every run, recording per-axis evidence (producers,
  consumers, execution tiers, persistence, lifecycle states, migration/coexistence surfaces,
  and coupled tests/docs) before the first clarification question. A bundle-coverage gate fires
  at the same two sites as the derivation gate, the per-round Definition-of-Ready re-check keeps
  the bundle current, and the implementation-approach fork question's `(Recommended)` marking
  must cite a bundle entry by axis name while disclosing any unestablished axes. A consumer
  `## Evidence axes` prompt-extension section extends the generic floor. Step 3.6 now adjudicates
  every audit finding into must-revise / advisory / invalid-unverified classes; the T1 offer
  trigger and a new convergence query consume the post-adjudication unresolved-must-revise count
  instead of the raw `VERDICT: REVISE` token (T2's fail-closed coverage is unchanged), and the
  `issue-audit-state.py` state owner gains `record-adjudication` / `query-convergence`
  subcommands and extended summary fields. (#548)
