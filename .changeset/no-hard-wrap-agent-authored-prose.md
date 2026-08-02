---
bump: patch
---

### Fixed

- The shared writing standard now states that agent-authored prose is not hard-wrapped: each paragraph and bullet is one line and the renderer wraps it. Drafted issue bodies were arriving with prose broken at a fixed column, which GitHub renders as ragged short lines and which makes every later edit rewrap the whole paragraph. Nothing in the write path reflowed the bytes — no rule existed in either direction, so the drafting agent's habit decided it.
