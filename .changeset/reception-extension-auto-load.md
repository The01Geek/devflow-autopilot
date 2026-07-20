---
bump: minor
---

### Added

- `/devflow:review-and-fix` now loads `.devflow/prompt-extensions/receiving-code-review.md` at skill entry, alongside its own extension, so a repo's reception policy reaches every fix loop that enters through the skill preamble — the standalone loop, the `/devflow:implement` Phase 3 inline run, and the Step 2.6 shadow entry — instead of only a direct `/devflow:receiving-code-review` invocation. (The documented Skill-denied fallback, where Phase 3 reads the engine straight from the tree, bypasses that preamble and loads neither extension — a pre-existing gap this change does not close.) The skill preamble carries scoping prose governing how an unattended loop consumes text written for an interactive direct pass, including an authority guard that weighs a mid-loop spec supersession by whether its author holds repository write permission.
- DevFlow's own reception extension gains two sections porting rules already proven on the fix-loop path: focused test-module iteration (adapted to lead with the direct runner form, which the local-tier classifier permits where it denies the `bash <path>` wrapper), and the explicit push destination ref `git push origin HEAD:refs/heads/<head ref>`, with the bare-`git push` refusal and the `git push -u` straight-to-main hazard named as non-conforming within a reception pass.

Consumers with an existing `receiving-code-review.md` extension should audit it for interactive-only directives and for loader deliverability before bumping `devflow_version` — see the upgrade note in `docs/install.md`. Repos without that file are unaffected.
