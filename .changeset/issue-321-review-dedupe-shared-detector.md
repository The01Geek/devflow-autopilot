---
bump: patch
type: Fixed
---

- **Route the `review_dedupe` cloud job through the shared standalone-command detector.** The
  `review_dedupe` job in `devflow.yml` now materializes the vendored plugin and routes its body
  match through the same `detect-standalone-command.sh` the trigger resolver uses, replacing its
  coarse `case "$BODY"` substring. A `/devflow:review` merely quoted or fenced in prose no longer
  dedupes or posts a "manual review suppressed" notice, and the trigger gate and dedupe matcher
  can no longer drift. (#321)
