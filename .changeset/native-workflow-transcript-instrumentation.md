---
bump: patch
type: Added
---

- **Add native workflow transcript instrumentation.** Discover local Claude Code workflow sessions without exposing prompt content, retain only ephemeral start metadata automatically, and require explicit byte-verified import before creating analysis bundles. (#522, #525)
- **Honor a launch-line `DEVFLOW_RECORDER_MODEL`/`DEVFLOW_RECORDER_EFFORT` declaration in the start manifest.** A declared model or effort now fills in what the session did not itself report, instead of being silently dropped on the hooked launch path. An observation from the host still wins over a declaration.
- **Report analysis evidence that could not be read.** A workflow bundle that fails to load is no longer dropped from `--last N` selection silently, and a corrupted `event-summary.json` is now distinguished from an absent one instead of both degrading to "unavailable".
- **Bound the analyst subprocess with a timeout.** `analyze-workflow-runs.py` no longer blocks indefinitely on a hung provider call; override with `DEVFLOW_CLAUDE_TIMEOUT` (seconds).
