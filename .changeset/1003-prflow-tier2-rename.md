---
bump: minor
---

### Changed

- **PRFlow rename Tier 2 (issue #1003)** — the three consumer-visible brand identifiers move,
  and every reader of a pre-rename artifact keeps resolving it.
  - The **provenance label** new runs stamp is now `PRFlow`. Every selector accepts **both**
    `PRFlow` and the superseded `DevFlow` (`lib/scan.sh`, `lib/classify-pr-kind.jq`,
    `lib/fetch-pr-context.sh`), so no retrospective history is dropped. The API-side filter
    now uses a single `--search "… label:PRFlow,DevFlow"` qualifier — `gh pr list --label A
    --label B` is an **AND** and would have returned zero candidates silently.
  - The **telemetry branch** default is now `prflow-telemetry`. Records already published on
    `devflow-telemetry` are not migrated automatically; the unmigrated state is *detected*
    with a breadcrumb naming the one-line `git push origin devflow-telemetry:prflow-telemetry`
    migration (see `docs/efficiency-trace.md`).
  - **Comment markers** newly written carry `<!-- prflow:… -->`. No existing issue or PR body
    is rewritten. Readers of persisted GitHub artifacts accept both spellings **per record**,
    so a workpad mutated in place across the rename boundary still discharges its pre-rename
    `deferred-filed` records and binds its pre-rename `scope-decision pr=pending` ones.
    In-tree reference boundaries (`*-ref`) and the in-run `dispatch-scope` file-format marker
    are renamed in place with no dual form.
  - `deferred.labels` defaults to `PRFlow,Deferred`.

### Fixed

- `scripts/match-lint-adjudications.py`'s adjudication-sentinel tamper guard now counts the
  **union** of both marker spellings. Counting each spelling independently would have let one
  genuine new-form section sit beside one attacker-quoted old-form section, read as `1` and
  `1`, raise no tamper flag, and honor the forged window. The review engine's producer-side
  neutralization list names both spellings to match.
- Every fail-open marker reader is fixed rather than documented: both trigger resolvers, the
  `#989` review-backstop dedupe override, the stall-backstop lifetime attempt counter and the
  review-backstop per-head attempt counter now match or count both spellings — a marker miss
  in any of them was a duplicate-run or suppressed-resume bug, not a cosmetic gap.
- `.prflow/config.schema.json`'s `docs.labels` default was `DevFlow`, disagreeing with the
  shipped example config, the live config and the resolver default; it is now `Documented`.

### Added

- `lib/rename-map.json` gains a top-level `identifiers` rename channel with per-entry match
  semantics (`token` / `prefix`), and `lib/test/pin-corpus-lint.py` compiles it. The alternation
  is ordered longest-literal-first with frozen entries winning ties, and the builder now refuses
  a name that is both frozen and mapped, an unrecognised top-level block, and an identifier
  entry with no declared match — three edits that were previously silent no-ops.
