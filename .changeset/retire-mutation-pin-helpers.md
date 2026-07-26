---
"devflow-autopilot": patch
---

Retire the remaining mutation-taking pin helpers, replace their genuine behavioral
boundaries with ordinary executable tests, and require the audited mutation-helper
census to remain empty. Authoring guidance now directs behavioral regressions to
executable RED/GREEN coverage, while a derived consistency guard keeps the historical
disposition totals and live inventory summary synchronized.
