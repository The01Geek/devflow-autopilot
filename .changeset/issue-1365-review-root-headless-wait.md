---
bump: patch
---

The review engine root now states its cloud headless-wait barrier the same way the implement root does: every dispatched subagent's completed result is collected before the orchestrator proceeds past the dispatch point and before the turn ends, with more than one dispatch permitted to be outstanding at a time provided every one is collected within the turn. The previous per-dispatch "blocks until" phrasing described something the engine does not do — its own verification phase batches up to eight verifier dispatches in a single message under this same barrier — so a reviewer agent reading the root literally could serialize a batch it was entitled to run concurrently. The prohibition on treating a launch acknowledgment as the return is unchanged, as is the framing of `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` and `run_in_background: false` as current runner examples rather than as the definition. This is a clarification of meaning, not a relaxation. (#1365)
