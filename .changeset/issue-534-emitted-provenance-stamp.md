---
bump: patch
type: Fixed
---

- **Persisted iteration records now affirmatively record their provenance.** `lib/efficiency-trace.sh --persist` deterministically stamps `synthesized: false` onto the durable copy of any agent-written `iter-<N>.json` record that lacks a `synthesized` key, moving the emitted-record provenance stamp off the agent's decision path. An emitted record (`.synthesized == false`) and a backstop-synthesized one (`.synthesized == true`) are now distinguished by a deterministic JSON boolean rather than by field-absence, so a skipped emit surfaces as the absent record. Synthesized records are unchanged (they already carry `synthesized: true`). (#534)
