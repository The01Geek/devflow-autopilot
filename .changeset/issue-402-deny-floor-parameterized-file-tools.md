---
bump: patch
type: Security
---

- **Reviewer deny-list floor now strips parameterized tree-mutation tools.** The consume-time
  deny-list floor that keeps `Edit`/`Write`/`MultiEdit`/`NotebookEdit` off the cloud reviewer's
  write-token profile previously matched only bare tool names by exact string equality, so a
  parameterized entry in `devflow_runner.allowed_tools` (`Write(**)`, `Edit(src/**)`,
  `notebookedit(x)`) bypassed the floor and was granted to the reviewer. The floor now compares
  the tool name before the first `(` case-insensitively, stripping bare and parameterized
  file-tool entries alike and naming each in a per-entry strip warning. The filter logic is
  extracted into `scripts/filter-runner-tools.sh` (suite-driven over an adversarial input
  matrix), the workflow fails closed when the helper is absent, and the `denylisted` mirror in
  `scripts/detect-project-tools.sh` gains the same check. Consumer repos keep the read-only-tree
  guarantee even when a generated or hand-edited config smuggles a parameterized tree-mutation
  rule. (#404)
