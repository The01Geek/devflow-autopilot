---
bump: patch
type: Added
---

- **Review engine now files false-against-HEAD changed docs/comments/examples as documented falsehoods and runs a pre-verdict truthfulness sweep.** The shared `defect_signature` contract gains a `documented_falsehood` kind plus a truthfulness discriminator inherited by all six Phase-3 finding producers, so a diff-added/modified doc line, code comment, example, or command-form whose claim is false against HEAD is filed as a truthfulness defect rather than a demotable clarity Suggestion. Phase 4.1.5 shape 2 now excludes such artifacts from the cosmetic-wording class, and a new Phase 4.1.6 pre-verdict truthfulness sweep runs promote-only over every finding regardless of severity chip, routing a demonstrated falsehood into the Phase 4.2 self-contradicting-diff carve-out (REJECT). `/devflow:review`, `/devflow:review-and-fix`, and `/devflow:implement` Phase 3 all inherit the change through the shared engine. (#341)
