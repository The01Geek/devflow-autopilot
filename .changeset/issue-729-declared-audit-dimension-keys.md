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
  the specific shape) on a checklist bullet carrying no key declaration, a
  declaration followed by no bullet, a key that is not lowercase kebab-case, a
  duplicate generic key, or two consumer dimensions resolving to one key — the
  last naming the `dim-key` disambiguation remedy. Previously a colliding or
  reworded dimension could silently coalesce or rekey the enumeration that
  per-dimension coverage totality is checked against.

Coverage recorded under the previous derivation needs no migration: the state
owner treats coverage keys as opaque strings and checks a round's totality
against the `coverage_expected` keyset persisted in that round, never against a
fresh enumeration.
