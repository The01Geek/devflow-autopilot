---
bump: patch
type: Changed
---

- **Step 3.5's unstated-mechanism-dependency sweep now determines whether a depended-on capability exists before selecting a discharge route.** `skills/create-issue/references/step-3-5-steelman.md` item 4 widens its enumeration prompt with an existence-shaped exemplar class (renderer mode, persisted state field, subcommand/flag, config key), and resolves each dependency by determining existence first and then routing on that determination. The full rule has one home in item 4; the four sites that restated the old discharge pair (`issue-template.md`'s premise-class paragraph, its quality-checklist row, its Acceptance Criteria guidance paragraph, and `docs/DEVFLOW_SYSTEM_OVERVIEW.md` §11) now carry a pointer instead of a copy. (#1020)
