---
bump: patch
type: Changed
---

- **Guard implement-run verification against stale checkouts.** The `/devflow:implement`
  skill's phase files gain four bounded rules so a run that *adopts* a pre-existing branch no
  longer adjudicates truth against a checkout that may be days behind the base (the #325
  incident: a 43-hours-stale adopted tree falsely refuted a *true* "already shipped in PR #319"
  claim and re-implemented merged work into a human-resolved dirty merge). Phase 1.4's
  `USE_CURRENT` (adopted-branch) arm now runs the same breadcrumbed `git fetch origin "$BASE"`,
  records how far the tree is behind `origin/$BASE` (the behind-by-0 case included, so freshness
  is provably checked), and on a fetch failure records a freshness-unverified reflection and
  continues rather than hard-blocking. Phase 1.6 and Phase 2.1 carry two coupled-mirror rules: a
  **read-target rule** (shipped-work verification reads target `origin/$BASE` state when the
  branch is behind, when freshness is unverified, or when no freshness record exists at all —
  the workpad write is best-effort, so a missing record fails closed as unverified rather than
  reading as behind-by-0 — never the unfetched fork point) and a
  **cross-pass coherence rule** (a "shipped/landed in PR #N" claim is REFUTED from tree reads
  only after a read-only `gh pr view` shows PR #N MERGED *and* `git merge-base --is-ancestor`
  confirms the merge commit is in the checkout — MERGED-but-absent, or any indeterminate outcome,
  yields "checkout stale — refresh and re-verify", never "code wins"). The §2.1 code-wins
  paragraph gains the matching freshness qualifier. Phase 4.0's split-AC composition rule now
  requires an already-shipped annotation to name the sibling PR and its merge state at filing
  time, aligning the 2.2.5 verbatim guarantee with composed-annotation reality. No helper,
  workflow, allowlist, or config change — consumers inherit through the shared skill. (#429)
