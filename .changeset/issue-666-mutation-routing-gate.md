---
bump: patch
---

Mechanically enforce the behavioral-fix-pin mutation-check mandate. `lib/test/pin-corpus-lint.py`
gains a diff-scoped, fail-closed `mutation-routing` subcommand: a pin call site the change *adds*
through a non-mutation helper (`assert_pin_unique`, `assert_pin_red_on_removal`,
`devflow_module_pin_unique`, `devflow_module_pin_present`) must route through a mutation-taking
helper or carry a format-strict `# structural-pin-ok: <reason>` marker, else the suite goes RED. A
moved pin is exempt (one-to-one on its literal, never across a downgrade to a non-mutation helper).
A companion runtime overbreadth guard in the three mutation-taking helpers (`assert_pin_red_under`,
`assert_count_red_under`, `devflow_module_pin_red_under`) rejects a target-blanking mutation
(`1,$d` / `s/.*//`) that would flip any pin PASS→FAIL by destroying the file rather than the
guarded content.
