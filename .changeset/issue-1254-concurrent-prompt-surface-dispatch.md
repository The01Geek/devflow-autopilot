---
bump: patch
---

### Changed

- The implement engine's headless-wait barrier now states its requirement as **collect-before-proceeding**: every dispatched subagent's result is in hand before the run proceeds past the dispatch point and before the turn ends, and more than one dispatch may be outstanding at a time provided all of them are collected within the turn. The previous wording read as a per-dispatch block — one subagent at a time — which is not what it ever meant: the review engine already batches up to eight dispatches in one message under this same barrier, and keeping subagents in the foreground is not the same as serializing them. The prohibition on treating a launch acknowledgment as the return is unchanged, and the runner mechanisms are still named as current examples rather than as the definition, so the rule still holds on a runtime that exposes no equivalent switch. (#1254)
