---
bump: patch
type: Added
---

- **The implement tier now carries the exact resolved allowed-command list in its own prompt.** `devflow-implement.yml` prepends the engine-ground-truth block (rendered by the shared `scripts/render-grounding-block.sh` in a new `MODE=implement`, which emits the permitted-commands, command-shapes, and headless-run sections and omits the review-only CI and displaced-paths sections), so an implement agent can self-diagnose a silently-refused command against a list it already holds instead of guessing. The implement `--allowed-tools` region is hoisted into a `Resolve allowed-tools` step output that both `claude_args` and the block consume, so there is no second, hand-copied copy of the allowed-tools text. This does **not** make a denial visible at the moment it happens and does not change the matcher's response; it gives the agent the list to check against. (#1170)
