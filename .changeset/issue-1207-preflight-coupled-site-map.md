---
bump: patch
type: Added
---

- **The implement engine now maps coupled sites *before* editing, not only after.**
  `skills/implement/phases/phase-2-implement.md` gains a §2.2.7 "Pre-flight coupled-site
  map" step, placed after §2.2.6 and before §2.3. When the plan touches a value, contract,
  or literal replicated across more than one place, the run now lists those other places
  first — enumerating them with searches it actually runs (in the granted forms and order
  the §2.3 "Sweep selection" preamble already gives), recording the commands and their
  results through the workpad before the first edit, and recording any refused search — or
  any search that cannot be confirmed to have run — as a gap rather than treating an unrun
  search as "there were no other places," while an honest zero-match result stays clean. A project that
  publishes a coupled-site registry is told to consult it too, worded so it reads correctly
  where none exists. This runs the same check the §2.3 relocation and contract-completeness
  sweeps make after the edits, so a missed copy is caught up front instead of when the
  suite goes red or a reviewer rejects the change. `CLAUDE.md` no longer points a reader at
  `git grep` (granted in no capability profile, so silently refused on the cloud runs); both
  occurrences are reworded to a permitted search form. (#1207)
