---
bump: patch
---

### Added
- The cloud runner now preserves the engine's execution transcript as a
  short-retention run artifact (`claude-execution-transcript-<run>-<attempt>`),
  token-scrubbed and gated by the NEW opt-in (default-false, fail-closed)
  `devflow.execution_transcript_artifact_enabled` key — a consumer must opt in; this repo's own config.json enables it. Follow-up to issue #401: three
  no-verdict review stalls ended on a voluntary final message that was never
  readable because the execution file died with the runner — the next stall
  becomes a read, not an inference (evidence trail on issue #401, PR #397).
