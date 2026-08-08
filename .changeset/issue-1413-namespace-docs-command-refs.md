---
bump: patch
type: Fixed
---

- **Namespace the `docs-*` cross-command references so a consumer can run what a stop arm names.** Six unnamespaced `/docs-*` command references across three `docs-*` skill bodies (`docs-bootstrap-internal`, `docs-sync-external`, `docs-bootstrap-external`) now use their `prflow:` form, so an agent following a Preflight stop arm reports a command that actually resolves in a consumer's checkout. (#1426)
