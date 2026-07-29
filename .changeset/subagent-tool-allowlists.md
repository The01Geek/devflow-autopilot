---
bump: patch
---

### Changed

- **Every DevFlow-authored subagent now declares an explicit `tools:` allowlist.** The three
  `checklist-*` agents and the five vendored `pr-review-toolkit` review agents
  (`code-reviewer`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`,
  `type-design-analyzer`) previously carried no `tools:` key, so each inherited the full
  subagent toolset — including `Edit`, `Write`, `MultiEdit`, `NotebookEdit` and `Task` —
  while five of them state a read-only advisory working-tree policy in their own bodies
  ("never modify working-tree source files, the index, HEAD, or branch state"). That policy
  was requested in prose and unenforced by the harness. Each agent now names only what its
  body and its dispatch prompt actually use: `Read, Grep, Glob` for `checklist-generator`,
  `Read` for `checklist-deduper` (a pure JSON-to-JSON merge), and `Read, Grep, Glob, Bash`
  for the five review agents, whose `git diff` / `git show` scope reads and `mktemp`
  mutation-checks need Bash. `checklist-verifier` additionally keeps `Write`, because the
  Phase 2.1b dispatch prompt instructs it to write its verdict JSON to `{VERDICT_FILE}`.
  `Task` is dropped everywhere: none of the eight dispatches a subagent.

  **This is a name-level boundary, not read-only enforcement.** The six agents that hold
  `Bash` can still reach the working tree through it (`sed -i`, `git checkout --`, `git
  reset`). What the change closes is the tool-shaped path — an agent reaching for `Edit`
  or `Write` on a file it was told only to report on. The Phase-3 dirty-tree snapshot guard
  remains the behavioral backstop, and per-tool argument scoping (`Bash(git show:*)`) is a
  possible follow-up: such entries parse and round-trip, but whether they are *enforced* as
  scoping is not yet measured.

  Restricting an agent has one non-obvious failure mode, measured on Claude Code 2.1.220 and
  now guarded: a `tools:` key whose value is **empty** — bare, `[]`, or `""` — parses
  identically to omitting the key, so the agent inherits every tool. An emptied value is a
  silent fail-open of this boundary rather than the tightest possible restriction, which is
  why the new suite rows prove each value is non-empty before testing what it omits.
