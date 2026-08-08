---
bump: patch
---

Remove the shipped skill surface's pointers to `.github/workflows/matcher-probe.yml`, and add a
never-shipped-workflow forbidden class to `lib/test/lint-shipped-pruned-path.py` so the family
cannot come back.

A `skills/**` body is copied verbatim into a consumer repo while `devflow_copy_slice()` copies
no `.github/` at all, so the pointer lines told a consumer to consult and re-run a workflow their
repository does not contain. Those pointers are gone, with each paragraph's
instruction restated inline. The new lint class derives the forbidden set at run time by
word-list membership over the workflow copy loop and `DEVFLOW_WITHHELD_TIER` in `install.sh`, so
a workflow the installer starts shipping leaves the set with no edit to the lint; an
unestablished declaration refuses non-zero naming `install.sh` rather than auditing against an
empty set.
