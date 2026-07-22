---
schema: 1
kind: growth
---

## Files

- `CLAUDE.md` — +1,278 bytes (72,592 → 73,870).

No mandatory row is reduced or relocated by this change, and no prose ownership transfers, so
`growth` is the only audited decision this diff needs. The prose, comment, and schema-description
corrections in the same change touch `docs/`, `.devflow/config.schema.json`, and
`scripts/install-gh-wrapper.sh`, none of which the prompt-mass census measures.

## Justification

The single added bullet records a drive-letter `PATH`-split hazard that this repository already
contains a live instance of, in `scripts/provision-python3-shim.sh`'s target-directory loop. It
belongs in `CLAUDE.md`'s Gotchas Windows-portability cluster rather than in a reference load,
because it is the load-bearing kind of gotcha an author consults *before* composing or splitting a
shell `PATH`-style variable on Windows — exactly the point at which the split silently produces a
directory name that was never meant. Stated only in the shim's own source it would leave the class
undocumented; stated without naming `GITHUB_PATH` as the non-instance it invites a future reader to
"fix" a newline-appended line that is correct as written and is the line issue #690's mechanism
depends on. Both halves — the live instance and the named non-instance — are required for the
bullet to act, which is why the byte cost sits in `CLAUDE.md` and not in a conditionally-loaded
reference.
