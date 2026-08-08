---
bump: patch
type: Changed
---

- **Editorially compressed the review engine's `phase-3-agents.md` and `phase-4-verdict.md` under the instruction-plus-consequence prose rule.** Each instruction now carries the instruction and at most one sentence naming what breaks if it is skipped; what was removed is maintainer notes directing no agent action, run-number incident history, and prose pre-empting a reviewer's misreading. The reviewer roster, the dispatched agent prompts, the verdict rules and their thresholds are unchanged, and each literal asserted by an in-tree pin over these files was re-counted after the change and holds byte-identical at its prior occurrence count. (#1460)
