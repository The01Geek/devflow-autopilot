---
bump: patch
type: Fixed
---

- **Bind `[[INTERNAL_DOC_LOCATION]]` in two more shipped skills.** `skills/implement/phases/phase-2-implement.md` and `skills/retrospective/SKILL.md` now carry the configuration preamble that reads `.docs.internal` through `config-get.sh` and binds the result to `[[INTERNAL_DOC_LOCATION]]`, and the prose and example sites in each that hardcoded a docs path now use the placeholder instead. A consumer who reconfigured `.docs.internal` is no longer handed the default path in these two skills. (#1310)
