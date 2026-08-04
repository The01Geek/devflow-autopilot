---
bump: patch
type: Changed
---

- **Relocated all internal documentation from `docs/` root to `docs/internal/`, making the public/internal split structural.** `docs/external/` remains the published Mintlify source; everything else under `docs/` now lives at `docs/internal/` (with `docs/execution-file-shape.observed.txt` moving to `lib/test/fixtures/`). `.prflow/config.json` now resolves `docs.internal` to `docs/internal/`, matching the shipped schema default. The vendor slice prunes `docs/internal` alongside `docs/external`/`docs/site`, so DevFlow's maintainer documentation no longer ships into consumer repositories, and `lint-shipped-pruned-path.py` is armed against reintroduction. (#1188)
