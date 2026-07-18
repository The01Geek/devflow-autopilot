---
bump: patch
type: Added
---

- **Truthful `/devflow:implement` startup lifecycle + workpad startup checkpoints.** A normal first cloud run no longer falsely records `/devflow:implement run resumed`: the workflow now decides run provenance (created / adopted / unknown) and Phase 1 selects truthful lifecycle wording from it, reserving "resumed" for adoption of an interim workpad from an earlier execution. Four `## Progress` checkpoints (gate acknowledgment, Claude job invocation, Phase 1 entry, Phase 1 hydration) timestamp the startup boundaries so maintainers can attribute startup latency from the workpad alone. `workpad.py` gains an offline `handoff-state` validator, an idempotent `update --checkpoint KEY TEXT` mutation, and `--expect-comment-id`/`--expect-status` hydration-race preconditions; the gate splits `workpad.py id`'s exit-1/exit-2 cases so a transient read failure can no longer trigger a duplicate workpad, and the Claude job fails loud before startup when the vendored `workpad.py` is missing. No new config key, permission, secret, or install mode; partially-upgraded consumers degrade to neutral provenance rather than breaking. (#537)
