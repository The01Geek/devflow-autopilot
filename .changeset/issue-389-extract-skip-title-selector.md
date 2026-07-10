---
bump: patch
type: Changed
---

- **Extracted `devflow-review.yml`'s inline `SKIP_REASON`→deferral-title selection into
  `scripts/describe-skip-title.sh`.** The `create_check` job's five-arm `case` that composed
  the "Devflow review waiting: …" check-run title now lives in a dedicated helper (mirroring
  `scripts/describe-denial-count.sh`), so the test suite drives every arm and asserts
  arm-order — a reordered or deleted arm now turns the suite RED instead of silently
  misattributing a deferral title. The titles are byte-identical and the honesty rule (never
  assert a state the precheck did not observe) is carried into the helper. (#393)
