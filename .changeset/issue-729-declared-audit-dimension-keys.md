---
bump: patch
---

### Changed

- `/devflow:create-issue` Step 3.6 audit dimensions are now first-class keyed data
  rather than a scrape of rendered prose (PR #732, issue #729). Each generic
  dimension in `skills/create-issue/references/audit-prompt-template.md` declares
  its stable key on a `<!-- dim-key: <lowercase-kebab> -->` line above its
  checklist bullet; `scripts/render-audit-prompt.py`'s `enumerate-dimensions`
  emits that declared key as `g:<declared-key>` and every rendering path strips
  the marker, so the human-facing checklist and the machine enumeration are two
  projections of one declaration. Rewording a dimension therefore leaves its key
  byte-identical, where previously it silently rekeyed a dimension that
  `scripts/issue-audit-state.py` had already recorded durably. Consumer
  `## Audit dimensions` bullets are keyed from their own optional declaration,
  else their bold-lead name slug, else a hash of their text — retiring the
  positional `c:<n>` keys that reshuffled whenever a consumer inserted a bullet
  mid-section.

### Fixed

- The renderer now fails closed (rc≠0, empty stdout, a stderr breadcrumb naming
  the specific shape) on a bullet carrying no key declaration, a declaration
  binding no bullet, a declaration separated from its bullet by a non-blank line,
  a key that is not lowercase kebab-case, and a duplicate key. Previously a
  colliding or reworded dimension could silently coalesce or rekey the enumeration
  that per-dimension coverage totality is checked against.
- **Both projections enforce those arms, and both arms are enforced symmetrically.**
  Validation runs on the render path as well as `enumerate-dimensions`, so a
  template or consumer defect can no longer render a full audit prompt while the
  orchestrator's operand call dies; and the consumer `## Audit dimensions` section
  is held to the same arms as this repo's own template **for the declarations it does
  carry**, with the breadcrumb naming the consumer extension rather than the template so
  an operator debugs the file actually at fault. An absent declaration remains legal (it
  selects the content-derived fallback), and a collision between two *derived* keys
  degrades on the render path rather than denying the auditor the prompt over a slug
  coincidence in a third-party file. Consumer declarations were previously discarded in silence,
  which left a consumer believing they had pinned a durable key while the
  enumeration quietly used the reword-unstable fallback instead.
- `.devflow/prompt-extensions/create-issue.md`'s own nine audit dimensions now
  carry explicit declarations, so this repo's consumer keys stop tracking bold
  leads that embed issue numbers.

Coverage recorded under the previous derivation needs no migration: the state
owner treats coverage keys as opaque strings and checks a round's totality
against the `coverage_expected` keyset persisted in that round, never against a
fresh enumeration.
