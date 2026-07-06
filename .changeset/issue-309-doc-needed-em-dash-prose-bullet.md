---
bump: patch
type: Fixed
---

- **`extract-doc-needed-paths.sh` now recognizes the `**Documentation Needed**`
  bullet when it is written as a bare bold paragraph with no leading `- ` list
  marker.** LLM-drafted `## Implementation Notes` sections commonly render the item
  as `**Documentation Needed** — …` rather than the template's `- **Documentation
  Needed** — …`; the extractor's scope anchor required the `- ` prefix, so it
  matched nothing and returned empty — silently skipping the Phase 4.1 deterministic
  deliverable cross-check on exactly that issue shape (the real issue #304 body
  triggered it). The Stage-A scope opener and closer now treat a bold line as a
  top-level bullet when it is either a `- **…**` list item or a bare, blank-line-
  preceded `**…**` bold paragraph — the actual grammar of both bullet shapes. A
  bold-emphasis span that only begins a wrapped continuation line inside the bullet
  no longer closes the scope, so paths on later wrapped lines are still captured
  (avoiding a fail-open that would silently drop deliverables). The unchanged token
  scan still decides what is a path, so backticked/bare file paths in the em-dash
  prose sentence are emitted while directory references and non-path parenthetical
  prose are dropped as before. A sibling of the #289 miss class. (#309)
