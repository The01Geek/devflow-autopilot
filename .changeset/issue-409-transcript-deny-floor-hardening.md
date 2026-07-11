---
bump: patch
type: Security
---

- **Hardened the cloud-tier execution-transcript artifact and deny-floor helper paths.** The
  transcript scrub step now redacts the base64 basic-auth `Authorization` header the checkout
  persists (in addition to GitHub tokens/PATs, Anthropic keys, and Bearer headers), prepends a
  best-effort-blocklist caveat header into the uploaded artifact and warns that the blocklist is
  incomplete, and advertises an upload path only when the scrubbed output is non-empty. The
  deny-floor helper-call block guards `mktemp` failure (failing closed instead of aborting the
  `tools` step) and anchors its vendored-helper resolution to the git repo root so a future
  `working-directory:` cannot silently flip every review to helper-absent fail-closed. The
  `execution_transcript_artifact_enabled` gate, its fail-closed default-off polarity, the
  file-tool deny-list lookalike/case behavior, and the schema retention/`retention-days`
  coupling are now pinned. (#409)
