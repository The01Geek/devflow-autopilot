---
bump: patch
type: Fixed
---

- **`/devflow:create-issue` now writes and displays its draft copy at the main repo root, so the shown path is correct inside a worktree.** A new best-effort helper `scripts/resolve-main-root.sh` resolves the main working-tree root (falling back to the current directory with a breadcrumb when git can't answer), and `create-issue` uses it to write the draft to — and display it as — an absolute `<main-root>/.devflow/tmp/issue-draft-<slug>.md` path. Previously the draft was written to a worktree-relative path that a user whose editor is rooted at the main repo could not open. (#333)
