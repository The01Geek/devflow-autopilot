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
  matrix), and the `denylisted` mirror in `scripts/detect-project-tools.sh` gains the same
  check. Consumer repos keep the read-only-tree guarantee even when a generated or hand-edited
  config smuggles a parameterized tree-mutation rule. (#404)
- **The extracted floor executes only from a trusted source.** Because the review job checks
  out the PR head, the workflow never runs the checked-out tree's copy of
  `filter-runner-tools.sh` (a pull request could edit the filter governing its own review —
  the trust-boundary regression the extraction would otherwise have introduced). The
  `baseprovision` step materializes the helper from the trusted base ref into `RUNNER_TEMP`;
  when the base ref carries none, the vendored copy is accepted only when the `vendor-plugin`
  action reports it was freshly fetched this run at the pinned `devflow_version` (the action
  now exposes a `vendor_source` output: `committed`/`self`/`fetch`). With no trusted source
  the workflow fails closed — no build/verify tools are appended and a warning names the
  rule. Self-hosting consumers must land DevFlow re-vendors on the base branch for floor
  tightenings to take effect on reviews. (#404)
