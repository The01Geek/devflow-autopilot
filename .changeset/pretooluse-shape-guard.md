---
bump: minor
---

### Added

- **PreToolUse command-shape guard for the review tier (#805).** `scripts/pretooluse-shape-guard.py` is a `PreToolUse` hook that denies a Bash command matching a probe-proven denied shape (`R1` leading-assignment, the `/tmp`-target arm of `R3`, `R4` interpreter head) and returns a `permissionDecisionReason` naming the permitted alternative — delivered at the moment of the offending call rather than as more advisory prompt prose. It fails open to `defer` on every malformed payload or internal error, writes a heartbeat breadcrumb on every invocation, and escalates the remediation on a second denial of the same arm (per-arm counts kept in a lock-guarded run-keyed store, idempotent across a duplicate `tool_use_id`). The arm split is expressed by a new `classify_arms()` in `lib/test/extract-command-shapes.py`. The guard and its `importlib` closure (`extract-command-shapes.py` + `extract-command-heads.py`) join the `#458` `HOOK_TARGETS` trusted-source floor, `scripts/detect-hook-closure-edges.py` learns the `spec_from_file_location` edge form, and `scripts/harden-stop-hooks.sh` installs a language-appropriate Python stub for a `.py` target.

### Changed

- **Denied-command visibility (#805).** `scripts/extract-execution-shape.sh` now emits the denied commands the execution file's `permission_denials` array carries (bounded, single-line JSON) alongside the existing count, and `scripts/render-grounding-block.sh` names the three denied shapes it previously omitted (`bash <path>` wrapper, process substitution, `simple_expansion`).
