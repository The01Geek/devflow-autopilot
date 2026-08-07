---
bump: patch
type: Changed
---

- **`/prflow:init` prompt trimmed to the instruction-plus-consequence prose rule.** Removed rationale essays, rejected-design records, incident archaeology, maintainer notes, and reviewer-misreading pre-emption from `skills/init/SKILL.md` (body prose and `#` comments in fenced blocks alike), keeping every instruction, prohibition, degraded arm, breadcrumb literal, exact command form, and closed-set enumeration. No behavioral change — the same helpers run in the same order with the same flags. (#1408)
