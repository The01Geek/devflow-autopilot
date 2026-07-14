---
bump: patch
type: Added
---

- **`/devflow:create-issue` now reconciles a multi-state contract's summary form against its per-state acceptance criteria at drafting time.** Step 3.5's "Hunt for what the draft omits" gains a within-text contract-reconciliation target: when a draft states a multi-state contract (outcome tokens, error/exit codes, a status enum, or a state machine) in more than one form, the drafter verifies no summary or table form lists fewer causes for a state than the detailed per-state ACs specify, and fixes any disagreement through the existing revise-and-re-gate loop. The check is scoped to drafts that actually state such a contract and makes no claim to catch a state only a not-yet-written implementation will emit. The issue template's bidirectional-orphan sentence folds in one clause — every enumerated contract state maps to ≥1 AC — and the DevFlow `create-issue` prompt extension sharpens its "Coupled mirror sites" dimension so a source form is internally reconciled before it is mirrored. (#465)
