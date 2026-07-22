---
bump: minor
---

Require positive per-dimension coverage evidence in the create-issue Step 3.6
fresh-context audit (issue #708). `render-audit-prompt.py` gains an
`enumerate-dimensions` mode that emits a canonical, keyed, count-stable list of
every required audit dimension (generic-floor `g:<slug>` entries plus consumer
`c:<n>` entries), so the orchestrator holds an authoritative operand to join the
auditor's per-dimension coverage outcomes to and to run the byte-identity floor
against.
