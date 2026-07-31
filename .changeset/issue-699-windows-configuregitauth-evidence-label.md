---
bump: patch
type: Fixed
---

- **Corrected the `configureGitAuth` evidence label on the Windows git-env pins.** `docs/cloud-setup.md`,
  `docs/install.md` and `.prflow/config.schema.json` no longer state that no cell of the `configureGitAuth`
  column has been observed on a self-hosted Windows runner. Each now records the one datum on record — a
  `/prflow:implement` job that completed on such a runner (maintainer-reported from a consumer's runner,
  2026-07-21; not independently reproducible here, no run identifier committed) — at the precision it
  supports: `GIT_DIR` certainly absent because the implement tier suppresses it, `GIT_WORK_TREE` only
  *inferred* absent from the completed plugin install, with a pre-existing marketplace checkout on a
  persistent self-hosted runner named as the falsifier and the run's git-env step output named as the
  evidence that would settle it. The both-pins-off default row records that contradicting observation
  instead of a flat *fails*, and the abort claim is scoped to that row and marked inferred at all three
  sites. Schema edit is confined to description text — no key, type or default changes. (#699)
- **Stated the full rejection disjunction in `scripts/install-gh-wrapper.sh`'s multi-line-capture comment.**
  The comment gave one rejection mechanism as though it were the only one; it now names both routes a
  polluted capture is rejected along, and records the one shape that legitimately passes on the measured
  mode value alone. Comment-only change — no executable line differs. (#699)
