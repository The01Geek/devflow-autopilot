---
bump: patch
type: Fixed
---

- **Set `GIT_DIR`/`GIT_WORK_TREE` on the `Run Claude Code` step of the generated workflows so bot git-identity config succeeds on self-hosted Windows runners.** `devflow.yml`, `devflow-implement.yml`, and `devflow-runner.yml` now declare step-scoped `GIT_DIR: ${{ github.workspace }}/.git` and `GIT_WORK_TREE: ${{ github.workspace }}` on the `anthropics/claude-code-action@v1` step, so the action's `configureGitAuth` startup resolves the repository independent of the inherited working directory. This fixes the `fatal: not in a git directory` (exit 128) job abort that self-hosted Windows adopters hit at startup; GitHub-hosted Linux runners are unaffected (on a plain branch checkout `--git-dir` equals `--git-common-dir`, so worktree detection is unchanged). The vars are step-scoped so other steps' git operations are untouched, and ship to every consumer via `install.sh`. (#643)
