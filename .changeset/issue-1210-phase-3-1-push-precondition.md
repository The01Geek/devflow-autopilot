---
bump: patch
type: Fixed
---

- **Phase 3.1 now ensures the feature branch is pushed before `gh pr create`, and the create fence names the cause when it fails.** `gh pr create` only defaults `--head` correctly when the branch is already pushed at the same commit; Phase 3.1 previously assumed this without stating or ensuring it, so an unpushed branch made `gh` refuse and the fence reported every failure as the single word `create: failed`. Phase 3.1 now pushes `HEAD` to an explicitly-named destination (`origin` + the branch's full ref, never a bare `git push`) right before the create, the create fence captures `gh`'s stderr and carries it into the `blocked` note, and the corrected cause is documented (a `gh` refusal that cannot confirm a pushed branch and cannot prompt — not a git-worktree effect, since `refs/remotes/*` is shared). Phase 2.5's commit-push now detects and acts on a failed push, naming the local permission-refusal and cloud `.github/workflows/`-only rejection modes. (#1210)
