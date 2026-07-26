---
bump: patch
---

### Fixed

- Corrected a `lib/test/run.sh` comment that claimed the `#780` partial-gather arms kill the `is True`/`is False` identity mutants; those arms assert the gather refusal, which returns before the classifier's identity reads are reached.
- `scripts/preflight.py` now records which three upstream guards the identity reads' equivalence depends on, so relaxing one is a visible change rather than a silent loss of coverage.
- Added coverage for a JSON-null `open_pr_selected_by` — a non-string shape `gh pr list --json` can serialize — confirming it is refused by the same named cause as an out-of-enum string.
