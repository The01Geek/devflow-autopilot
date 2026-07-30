---
bump: patch
---

### Changed

- The pin-corpus authoring gate now **routes** a changed pin site through an ordered
  three-step ladder instead of returning on a single prose test (issue #948): (1) a
  program in `scripts/**`, `lib/**` outside `lib/test/`, or `.github/**` demonstrably
  reads the literal or a machine-identifier-shaped token it names — pass; (2) otherwise
  the delta-gated ledger `lib/test/pin-corpus-adjudications.tsv` already records the
  literal as `boundary` **and** the site carries a valid `# structural-pin-ok:`
  declaration — pass, the marker acting as a pointer to that authorized decision; (3)
  neither — the finding stands, naming which half was missing. Step 1 can only ever
  route a site down to step 2, and step 2 fails closed: a tag with no ledger row, a
  ledger row with no tag, a row in any other bucket, and an unestablished ledger are all
  findings. The `# structural-pin-ok:` escape hatch, previously unreachable for any
  literal the lint classified as prose, is usable again — so a retained pin with a
  recorded boundary decision can carry its reason at the site and be edited normally.
  A declaration whose grammar is invalid is still decided *before* the ladder, a retired
  wording literal's revival keeps its stronger pre-existing contract, and an
  unresolvable declaration target is still unfixable.
