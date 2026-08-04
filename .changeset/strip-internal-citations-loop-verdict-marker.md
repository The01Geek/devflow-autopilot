---
bump: patch
type: Changed
---

- **Remove PRFlow-internal provenance citations from the loop-verdict-marker prose in three consumer-shipped skill bodies.** `skills/implement/phases/phase-3-review.md`, `skills/review-and-fix/SKILL.md` and `skills/review-and-fix/references/loop-exit.md` ship verbatim into consumer repos, where an internal issue number resolves to nothing and an acceptance-criterion tag (`AC5`) resolves to nothing at all. Five citations are dropped — three `(issue #1212)`, one `(issues #843/#876)`, and the `AC5` tag in the safe-direction rule, which now reads `**Safe direction — non-negotiable.**` and keeps its binding force. The marker mechanism, its closed routing vocabulary, and the safe-direction rule itself are unchanged: they are a real contract between `/prflow:implement` and `/prflow:review-and-fix` that a consumer repo depends on, so they stay in the shipped skills rather than moving to a prompt extension. Prose-only; no behavior changes. (#1212)
