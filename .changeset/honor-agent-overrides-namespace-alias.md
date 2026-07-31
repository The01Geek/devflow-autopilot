---
bump: patch
---

### Fixed

- `agent_overrides` keys spelled with the transitional `devflow:` namespace are honored again. `.devflow/config.schema.json` enumerates every review-engine subagent under both declared namespaces — the canonical `prflow:` and the `devflow:` alias, "so an override committed before the plugin rename keeps resolving" — but `scripts/resolve-review-overrides.py` looked entries up by exact dispatched subagent id, and the engine dispatches only the canonical spelling. An alias-keyed override was therefore read as absent and silently discarded. The resolver now probes every accepted namespace spelling of each dispatched agent, in a deterministic positional precedence (the dispatched spelling first, then the remaining namespaces in `lib/plugin-identity.json` order), and warns when a lower-precedence duplicate spelling is shadowed instead of dropping it without a diagnostic. An alias-keyed entry is an own entry, so it shadows `default` exactly like a canonically-keyed one; a key whose namespace is not an accepted one is never adopted as an alias.
