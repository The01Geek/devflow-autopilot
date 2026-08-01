---
bump: patch
type: Changed
---

- **Step 3.5's unstated-mechanism-dependency sweep now determines whether a depended-on capability exists before selecting a discharge route.** `skills/create-issue/references/step-3-5-steelman.md` item 4 widens its enumeration prompt with an existence-shaped exemplar class (renderer mode, persisted state field, subcommand/flag, config key), and resolves each dependency by determining existence first and then routing on that determination. The full rule has one home in item 4; the three sites that restated the old discharge pair (`issue-template.md`'s premise-class paragraph, its quality-checklist row, and `docs/DEVFLOW_SYSTEM_OVERVIEW.md` §11) now carry a pointer instead of a copy, and `issue-template.md`'s Acceptance Criteria guidance paragraph — which stated the obligation-arm execution-tier constraint rather than the discharge pair — gains a pointer plus a clause naming the two obligation forms that are discharged by naming work rather than by running a probe. (#1020)
