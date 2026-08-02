---
bump: patch
type: Added
---

- **`/prflow:init` now offers an opt-in, consent-gated PRFlow rename sweep after a successful
  DevFlow→PRFlow layout migration.** After the atomic migration reports terminal `APPLIED`, init
  offers a repository-wide semantic sweep that finds and repairs stale `DevFlow` product-name
  prose the mechanical rename map cannot classify. The sweep discloses model access to tracked,
  untracked, and ignored file contents before consent, starts only on an explicit yes, enumerates
  candidates with three NUL-delimited `git ls-files` queries, records bounded base64-encoded
  progress pages under `.prflow/tmp/init-rename-sweep/`, pins the rename-map authority object ID
  per batch, and replaces each candidate through verified same-directory atomic writes with a
  preserve-by-default semantic predicate. A declined or non-interactive run makes no sweep writes;
  an incomplete sweep is never reported as clean; and a later `ALREADY MIGRATED` run offers a
  renewed-consent resume when a matching incomplete ledger exists. (#1164)
