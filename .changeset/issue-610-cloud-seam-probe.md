---
bump: patch
type: Added
---

- **Cloud per-agent-effort seam probe (issue #610, carried from #554).** Adds
  `.github/workflows/agents-seam-probe.yml` — a repo-internal, human-dispatch probe
  (mirroring `matcher-probe.yml`) that empirically establishes whether
  `claude-code-action` forwards a startup `--agents` JSON from `claude_args` (fact i,
  deterministically measured) and whether an `effort` on that startup agent-definition
  governs a runtime Agent-tool dispatch (fact ii, human-adjudicated from the subagent's
  self-report). Its verdict is computed by the unit-tested helper
  `scripts/agents-seam-probe-verdict.py` (SEAM_PROVEN / SEAM_FORWARDED / SEAM_UNPROVEN /
  INCONCLUSIVE), and the spike-gated *applied arm* ships only on `SEAM_PROVEN` — which
  requires the explicit human `--adjudicated-governed` flag. The probe is authored but
  not yet dispatched, so the seam stays unproven, the cloud per-agent-effort row remains
  honest fallback identical to local, and no per-agent effort application code ships (AC1's
  own contingency). Evidence of record: `docs/agents-seam-probe.md`; `docs/review-agent-overrides.md`
  is reconciled to point at the probe. (#610)
