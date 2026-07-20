---
bump: patch
---

### Added

- `scripts/stale-prose-lint.py` now emits a stderr breadcrumb when a `STALE` row is demoted to a non-gating `UNRESOLVABLE` under the issue-#629 move-aware relocation exemption: one per-row line naming the path and line, plus a single end-of-run summary line when the demotion count is non-zero. Demotion was previously the only silent non-gating downgrade in the helper, discoverable only by grepping the detail prefix. Additive on stderr only — the stdout TSV, exit-code arms, and Phase 0.6 row routing are unchanged. (Issue #636)
