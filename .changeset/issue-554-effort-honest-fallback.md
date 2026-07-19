---
bump: patch
type: Fixed
---

- **Review engine no longer overclaims that a per-agent `effort` override is applied.** On the
  in-session Agent-tool dispatch path both tiers use today, a per-agent `model` override is
  delivered (via the Agent tool's `model` parameter) but a per-agent `effort` override is **not**
  deliverable per-agent — no Agent-tool effort parameter and no per-dispatch `--agents` injection
  exist. `scripts/resolve-review-overrides.py` now decides the per-agent effort-application outcome
  (`session-fallback` for a resolved-but-unapplied override, `session-inheritance` for none) and
  emits a single honest `::notice::` summary (distinct from `::warning::`), so a configured effort
  is reported as a fallback rather than silently dropped while success is claimed. `effective` is
  null unless read back (unknown is not zero); a Haiku model or a provider with `effort_supported:
  false` is recorded as a capability-restricted fallback. The engine (`skills/review/SKILL.md`) and
  docs (`docs/review-agent-overrides.md`, `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, `docs/efficiency-trace.md`)
  are reconciled to the per-tier application-point matrix; the fictional per-dispatch `--agents`
  mechanism description is removed for model as well as effort. Model delivery is unchanged. (#554)
