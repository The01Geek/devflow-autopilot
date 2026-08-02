---
bump: patch
type: Fixed
---

- **Instructions and emitted runtime remedies now name the `prflow.<key>` config leaf their
  live reader actually reads.** Follow-up to #1068, which swept the `allowed_tools` grant
  instructions. Every remaining superseded `devflow.<key>` leaf across the tree is corrected so a
  message and the read it describes move as a pair. Four **emitted remedies** were the worst
  cases — following them could not work: `devflow-runner.yml`'s `::error::…allowed_bots is
  missing` (its adjacent read is `.prflow.allowed_bots`), `lib/scan.sh`'s watched-authors
  `::warning::`, `scripts/workpad.py`'s blank-`workpad_marker` breadcrumb, and
  `skills/review/phases/phase-4-verdict.md`'s "PR author is not in `…allowed_bots`" line rendered
  into a PR comment. The `docs/DEVFLOW_SYSTEM_OVERVIEW.md` §17 configuration-reference table — one
  table that carried both families side by side, with `prflow.allowed_bots`/`prflow.workpad_marker`
  correct but the provider row still reading `devflow.provider` — is reconciled. Frozen identifiers
  (workflow filenames, `DEVFLOW_*` env vars, `/devflow:<command>` aliases, the `devflow:<agent>`
  namespace, `devflow-marketplace`, the product name) and the deliberate both-spelling sites
  (`install.sh`, `docs/install.md`, the live migration regexes) are untouched. (#1084)
