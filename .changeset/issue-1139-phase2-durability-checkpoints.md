---
bump: patch
---

Phase 2 now makes mid-run work durable at each sub-step boundary. Previously an implement run held every change in an uncommitted working tree until Phase 2 §2.5 — its only commit and push — so a run that terminated earlier (an external interruption, an execution-ceiling kill) lost all of it. A new executable helper, `scripts/phase2-durability-checkpoint.sh`, commits and pushes explicitly-scoped paths at each Phase 2 sub-step boundary (and at §2.3's sweep boundaries), bounding the worst-case loss window to roughly ten minutes. The helper owns the cloud-tier workflow-edit guard's detect-and-do-not-stage behavior, refuses `git add -A`/`.`/intent-to-add, keeps §2.1.5 proof edits out of history by ordering, and treats a push as landed only when `git rev-parse HEAD` equals `@{u}`. (#1139)
