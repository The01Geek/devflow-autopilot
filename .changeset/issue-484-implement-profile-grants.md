---
bump: patch
---

### Added
- Grant the bundled helper set required by issue #484 on the implement profile (`devflow-implement.yml`). Phase 3's inline review engine calls `stale-prose-lint.py`, `match-lint-adjudications.py`, and `load-prompt-extension.sh`; the implement-owned surfaces call `react-to-trigger.sh` in the trigger-reaction fence and `extract-doc-needed-paths.sh` in Phase 4.1. The exact grant set also contains `dismiss-stale-rejections.sh`, whose call is in standalone-only review Phase 4.4 while inline implement review stops after Phase 4.3. The normal inline flow therefore does not invoke it, although the grant makes the capability available to the inline session; the source guard deliberately over-approximates shared fenced source and requires the grant for parity. Grant `cmp` for the inline review engine and `gh pr checkout` in `devflow.yml` for the manual `/devflow:review-and-fix` path (#363).

### Changed
- Anchor bare `workpad.py` fences in `skills/implement/phases/*.md` to the portable inline-anchor form the granted vendored literal covers.
- Rework the `react-to-trigger.sh` emission in `skills/implement/SKILL.md` to a leading-token form with CLI args (a leading `VAR=` env prefix was a denied matcher shape) and use `--report-failure` so the fence can record a failed reaction rather than swallowing it; the workflow's env-var path keeps its default best-effort exit-zero behavior.
- `load-prompt-extension.sh`'s guard distinguishes a matcher refusal from "no consumer extension" and queues the refusal note until Phase 1.3 has created or resumed the workpad.
- Rework `phase-4-documentation.md` §4.1's docs-commit fence so configured doc/release paths reach an explicit `git add` through validated printed tool output, not a `VAR=` read across a fence boundary; config-read failures block rather than masquerading as a clean no-change pass.
- Keep the inline final-pass reviewer read-only on commands available to every execution profile; unavailable `git worktree add`/`mktemp` mutation recipes now route to an attributable verification limitation.
- Move the shared Phase 3 dirty-tree snapshots and restore scratch from matcher-refused `mktemp` captures to fixed repo-local `.devflow/tmp/` files that survive the Agent-tool boundary, so the mandatory backstop executes on the implement profile.
- Harden those fixed paths against stale symlinks and fail closed when snapshot path extraction cannot be completed, so recovery never treats an empty or untrusted baseline as authorization to restore.

### Removed
- Inert `*/`-prefixed grant globs from `.devflow/config.json`'s `devflow.allowed_tools` and `devflow_implement.allowed_tools` — a `*/basename` glob does not match the vendored multi-segment leading token the matcher grants.

### Fixed
- Add a `lib/test/run.sh` head guard (#484) that drives `extract-command-heads.py` (new `implement-block` parse mode) over the fenced-command surface in `skills/implement/**`, `skills/review*/**`, and the dispatched `skills/requesting-code-review/**` final pass. It fails when a fenced emitted head is neither granted on the implement profile nor named in the exact deliberately-withheld list; the allowlist is assembled from the workflow alone, parse artifacts use a separate suppression list, and a removal-proof contract requires inline `workpad.py` shorthand to expand to the portable granted helper path before emission. Closes #484.
