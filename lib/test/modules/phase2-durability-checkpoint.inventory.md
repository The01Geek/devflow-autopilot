# Phase 2 mid-run durability-checkpoint contract module inventory

This inventory records the provenance of the focused Phase 2 mid-run durability
contract module (issue #1139). It is a navigation aid, not a second source of
behavior: `phase2-durability-checkpoint.sh` owns the executable assertions, and the
complete suite calls the same module through `module-harness.sh`'s
`devflow_run_full_suite_module` boundary. The `lib/test/run.sh` call site is
registered under the `#1139 Phase 2 mid-run durability checkpoint` box comment.

Source baseline: this is a **new module authored for issue #1139**, not an
extraction from `lib/test/run.sh` — the durability helper it exercises
(`scripts/phase2-durability-checkpoint.sh`) is new in the same change, so there was
no prior in-`run.sh` section to carry forward. No sibling candidate was left behind
in `lib/test/run.sh`.

Its assertion floor is recorded once, in
`scripts/workflow-flight-recorder-registry.json`, and enforced on every run by
`lib/test/run-module.sh`; `test_module_runner.py` reconciles that floor against the
`lib/test/run.sh` call-site literal. This inventory deliberately states no exact
assertion count — the registry is the single source, so a count copied here could
drift out of it silently.

Every assertion is behavioural: the helper is driven against a scratch git
repository with a **real bare remote** (the git plumbing under test is not mocked),
and judged on the resulting git state and the helper's exit code. There is no
wording-only pin here (issues #375/#666/#810).

| Contract group | Acceptance criterion | Representative contract |
| --- | --- | --- |
| RED control / GREEN | AC1, AC2 | with no checkpoint the branch is 0 commits ahead of base and the produced content is absent from the remote (today's behavior, as observable git state); after the helper runs, the content is on the remote branch and the branch is ≥1 commit ahead |
| Per-invocation behavior | AC3 | two calls with new work between them add exactly one commit each, each carrying only the work since the previous call; a call with nothing new adds no empty commit |
| Cloud-tier workflow-edit guard | AC4 | on a cloud-tier run with `DEVFLOW_APP_ID` empty, a tracked edit and an untracked addition under the repo's own `.github/workflows/` are neither staged nor committed, while non-workflow work still lands (only the detect-and-do-not-stage half lives in the helper); a stage-all spelling is refused before it can bypass the guard, and a repeated `./` prefix does not slip the guard's own normalization |
| Proof-edit exclusion | AC5 | a §2.1.5 proof file present but not named to the helper never enters a commit; history is not rewritten (the base stays an ancestor of the tip) |
| Explicit-path scoping | AC6 | an unrelated untracked file is not carried into the commit; the helper refuses the whole class of arguments that stage more than the caller named — option-shaped tokens, git magic pathspecs, and every whole-tree spelling (the `.`/`/` navigation forms, the match-everything wildcards, the empty string) — while a caller-named directory is still accepted as the negative control |
| Landing verification | AC7 | a rejected non-fast-forward push and an `Everything up-to-date` no-op both leave `HEAD` unequal to `@{u}` and are reported as a failure to land (exit 3) |
| Idempotency | AC8 | re-running with no change adds no empty commit; a resumed run adopting the branch sees the prior content exactly once |
