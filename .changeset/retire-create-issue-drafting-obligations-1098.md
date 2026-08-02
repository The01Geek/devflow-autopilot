---
bump: patch
---

Retire the `/prflow:create-issue` drafting obligations that `/prflow:implement`'s Phase 1.6 already re-derives (#1098).

### Changed
- Removed the claim-baseline machinery from `scripts/issue-audit-state.py` — the `record-claim-baseline`, `query-claim-baselines`, and `check-claim-staleness` subcommands, their exclusive helpers, and the persisted `claims` payload (registered subcommand count 42 → 39).
- Retired the issue template's premise-verification block, claim-baseline protocol, and the occurrence-count *citation* requirement; narrowed the `Verified:` re-derivation-handle rule to the single path-plus-quoted-sentence form; named Step 3.6's pre-dispatch canonical write as the handle-check execution site.
- Moved the retained occurrence-count and negative-existence verify-before-asserting obligations into `step-3-5-steelman.md` (self-contained, no command/hit-list citation), and relocated the audit-run bootstrap (`init` + nonce-carry + `query-nonce` recovery) into `step-3-6-audit.md`.
- Removed the repo prompt extension's consumers-axis repo-wide sweep leg, leaving the Interaction-surface-map call-site reads.

### Added
- Two recurrence guards plus a classification fixture pair in `lib/test/modules/create-issue-contract.sh`: one fails when an `issue-audit-state.py` subcommand loses its last consumer, the other when the template mandates a `Verified:` handle form `check-verified-premises.py` cannot adjudicate.
