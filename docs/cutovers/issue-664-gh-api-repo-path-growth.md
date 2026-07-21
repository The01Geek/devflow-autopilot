---
schema: 1
kind: growth
---

## Files

- `skills/implement/SKILL.md` — +826 bytes (69,975 → 70,801).
- `CLAUDE.md` — +1,068 bytes (65,628 → 66,696).

No mandatory row is reduced or relocated by this change, and no prose ownership transfers, so
`growth` is the only audited decision this diff needs.

## Justification

Both additions state the same newly-narrowed contract at the two places an author actually
reaches it, and neither is restatable as a reference load: the `skills/implement/SKILL.md`
bytes sit **inside** the *Outcome reaction on the triggering comment* fence, which every
terminal `Status` transition executes on both tiers, and the `CLAUDE.md` bytes sit in the REST
gotcha an author consults *before* writing a `gh api` fence.

- `skills/implement/SKILL.md` (+826). Four comment lines above the comment-listing call state why
  the path uses the `{owner}/{repo}` placeholders — that `$GITHUB_REPOSITORY` is empty outside
  Actions, and that `gh` writes the HTTP error body to **stdout**, which `2>/dev/null` does not
  silence. Six more explain why the admission test is a digit-only parameter expansion riding
  inside the existing `[ … ]` rather than a new `case` statement (it adds no command head for the
  implement-profile head guard and no new shape for `extract-command-shapes.py --profile
  implement`). Both are *provenance and rationale for a non-obvious shape* — the load-bearing
  comment class `CLAUDE.md` and §2.3's authoring rule retain rather than trim. Without the stdout
  fact in particular, the digit-only test reads as redundant belt-and-braces next to
  `2>/dev/null` and is exactly the kind of guard a later editor removes as noise, which is the
  regression `assert_pin_red_under` now pins.
- `CLAUDE.md` (+1,068). The pre-existing bullet named `$GITHUB_REPOSITORY` as an *interchangeable*
  source for a REST path. The replacement narrows it by surface (outside-Actions surfaces use the
  placeholders; `.github/workflows/` and `.github/actions/` are exempt because a checkout-less job
  has no remote to resolve from), gives the empty-outside-Actions rationale with the stdout
  consequence, and names `lib/test/lint-gh-api-repo-path.py` as the enforcing mechanism. A rule
  stated without its counter-case invites the wrong fix in the exempt directories, and a rule
  stated without its enforcing mechanism leaves an author unable to find why the suite went RED.

The growth is confined to these two files. The new scanner, its fixtures, and the `#664` suite
block are all under `lib/test/`, which the census does not measure as prompt mass.
