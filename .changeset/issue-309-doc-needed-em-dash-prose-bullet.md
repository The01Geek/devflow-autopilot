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
  triggered it). The Stage-A scope opener and its peer-bullet closer now accept an
  optional `- ` marker (`^(- )?\*\*`); the unchanged token scan still decides what
  is a path, so backticked/bare file paths in the em-dash prose sentence are emitted
  while directory references and non-path parenthetical prose are dropped as before.
  A sibling of the #289 miss class. (#309)
