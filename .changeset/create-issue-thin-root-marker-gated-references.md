---
bump: patch
---

### Changed

- `/devflow:create-issue` is now a thin always-loaded root plus marker-gated references.
  `skills/create-issue/SKILL.md` drops from 24,473 words to 2,623 — it keeps the portable-anchor
  preamble, the extension load, the core principle, the completion checklist, Step 1, Step 3's
  drafting rules and no-options gate, a reference routing table, and four non-degradable
  invariants. The five step procedures (Step 2, Step 3.5, the shared Revision-delta procedure,
  Step 3.6, Step 4) and four conditional fallback arms (no task tool, read-only sandbox, audit
  dispatch arms, state-owner unavailable) move verbatim into `skills/create-issue/references/`,
  each behind a first-line/last-line boundary-marker entry gate. Skill semantics are unchanged:
  a default-path run reads the same procedures it always did, and now sheds 2,291 words of
  fallback prose whose predicates cannot fire on that path.

### Added

- `docs/create-issue-budget.md` records the root and default-path word budgets (measured by
  python3 word-splitting, never `wc -w`), the ratchet-down-only rule, the conservation check,
  and the decision record. Both ceilings are enforced by the test suite and report RED on exceed.
- The `create-issue` consumer prompt extension gains a **Measurement-command naming** evidence
  axis: a drafted quantitative acceptance criterion must name the exact command that measures it,
  or record `unestablished` — never leave an unnamed counter for the implementer to choose.

### Fixed

- A failed reference load degrades best-effort — an in-chat breadcrumb naming the file and the
  failure kind, then that routing row's named degraded behavior — so no load failure can terminate
  a run, preserving the skill's never-block-issue-creation contract.
