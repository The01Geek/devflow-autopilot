---
bump: patch
---

### Added

- Focused test module `harness-python-guards` (`lib/test/run-module.sh harness-python-guards`), carrying the monolith-only Python guard drivers whose subject is a single code unit and whose verification is self-contained — the `#600` create-issue audit-prompt renderer, the `#527` verification-launch baseline analyzer, the `#528` single-flight verification ledger, the `#668` reception-identity producer, and the `#591` coverage-map ratchet guard (its live-tree invocation and its unit test), plus a planted coverage-map drift as a positive control that the module goes RED when the coverage-map guard breaks. The blocks are moved out of `lib/test/run.sh`, not duplicated: the complete suite still runs them through the `devflow_run_full_suite_module` boundary.

### Changed

- Focused verification is now the iteration default in the `implement`, `review-and-fix`, and `receiving-code-review` prompt extensions: a focused pass covering the changed surface is sufficient for an intermediate commit or push, and a full `lib/test/run.sh` run mid-iteration happens only when no focused module or path covers the changed surface — an implement run that performs one records a `## Devflow Reflection` bullet saying why. The final gate is preserved and, on the local/interactive and reception/shepherd tiers, parallelized: the push that triggers CI and the local full-suite run start together, the push is not gated on the local run, and the local run remains the authoritative local signal. The cloud `/devflow:implement` in-env gate (issue #405) and the issue-#456 skip accounting are unchanged.
