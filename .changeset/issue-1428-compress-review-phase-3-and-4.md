---
bump: patch
type: Changed
---

- **Editorially compressed the review engine's `phase-3-agents.md` and `phase-4-verdict.md` under the instruction-plus-consequence prose rule.** Each instruction now carries the instruction and at most one sentence naming what breaks if it is skipped; what was removed is maintainer notes directing no agent action, run-number incident history, and prose pre-empting a reviewer's misreading. The reviewer roster, the dispatched agent prompts, the verdict rules and their thresholds are unchanged, and the literals in-tree checks match against these two files were re-counted after the change and are byte-identical at their prior occurrence counts. (#1460)
