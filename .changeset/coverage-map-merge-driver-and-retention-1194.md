---
bump: patch
---

Stop coverage-map merges from silently dropping a key (#1194)

`lib/test/modules/coverage-map.json` is two large string-sorted JSON objects, so two
branches that each *add* a distinct key at an adjacent sort position conflict textually
even though they never semantically conflict — and resolving such a conflict by taking
either side silently deletes the other branch's entry, which the documented `--fix`
remedy cannot restore. Two mechanisms now close the class:

- New `lib/test/coverage-map-merge-driver.py`: a JSON-aware git merge driver, declared
  for the map in `.gitattributes`. It unions the `files`/`run_sh_blocks` objects per key
  (both distinct additions survive) and conflicts only on a genuine same-key divergence.
  It ships a `--register` path and a `--check` that fails RED — naming the exact
  registration command — when the driver is not active in the current clone, because a
  `.gitattributes` `merge=` attribute alone lets git fall back silently to its line-based
  merge. The merged output reuses the coverage guard's canonical serializer, so it is
  byte-identical to what `--fix` writes.
- New `lib/test/coverage-map-retention-check.py`: a CI-side key-retention check wired
  into `.github/workflows/ci.yml` (and desk-runnable against the same inputs). It compares
  the map at the merge base against HEAD and fails when a key — or its `note`/`owner`
  content — disappears in either half, covering the ~30 non-derivable `run_sh_blocks`
  keys no coverage-guard arm inspects and the web-conflict-editor path the driver cannot
  reach. Legitimate removals are declared with a non-empty reason in
  `lib/test/coverage-map-retention-allow.json`. It reports **three** outcomes rather
  than two, applying *unknown is not zero* to its own base comparand: `0` clean, `1` a
  dropped key or an unreadable input, and `3` "the base comparand could not be
  established". A shallow or partial clone previously reported the degraded comparand
  only on stderr and exited `0`, laundering a genuinely merge-dropped key into a green
  pass — including the shape that looks healthiest, where `git merge-base` *succeeds*
  against a truncated commit graph and names a boundary commit whose tree predates the
  map. Because a shallow clone is a legitimate desk workflow, the degraded case is not
  an unconditional hard failure: `--allow-degraded-base` is an explicit per-invocation
  acknowledgement that exits `0` while still printing the reasons and reporting the run
  as acknowledged-degraded, never as a verified clean pass. This also makes CI's
  `fetch-depth: 0` coupling self-enforcing — stripping it turns the step RED instead of
  silently removing the protection.

Both `--fix` remedy statements are corrected — `CONTRIBUTING.md`'s coverage-map section
and module-authoring checklist, and `lib/test/regenerate-artifacts.py`'s
`coverage-map-ratchet` `policy`/`conflict-recipe` — to stop presenting `--fix` as the
response to a merge-conflict resolution. Tests: `lib/test/test_coverage_map_merge.py`
drives the driver against real offline `git merge`s and the retention core over every
loss shape, wired into the `harness-python-guards` module (floor 43 -> 44). The coverage
ratchet's existing guarantee is unchanged.
