---
bump: patch
type: Added
---

- **Measure the `devflow.yml` command tier's command shapes.** The manual
  `/prflow:review-and-fix` / `/prflow:pr-description` command tier is now linted and probed
  on both axes the review and implement tiers already were: `extract-command-shapes.py`
  gains a `--profile command` desk lint (rule set `CR1`–`CR5`, inheriting the implement
  tier's denied shapes), and `matcher-probe.yml` gains a `command-probe` job whose
  allowlist baseline is a generated region compiled from the `command` profile — so a
  command-tier shape defect turns the suite RED at the desk instead of shipping as a burnt
  budget with a green check. Adds no grant. (#1298)
