---
bump: patch
type: Fixed
---

- **Fixed two reception defects in the vendored `receiving-code-review` skill.** The mutation-check recipe previously offered only a copy-based route ("on a copy of the file, never the working-tree file in place"), which is unsatisfiable for a suite that reads fixed paths or imports the module under test through fixed module paths — the majority case in consumer repos. It now states the invariant (the mutation is never left behind in the working tree, and the suite is observed RED for the reason the test pins) plus two routes: (a) mutate a copy where the suite can be redirected, and (b) mutate the working-tree file, run the suite, and restore — with an explicit restore verification — where it cannot, choosing (b) only when redirection is genuinely impossible. Separately, the *Symmetric Severity Calibration* section now has a rule for a review that annotates its own finding as a suspected over-grade: the annotation is advisory input to severity calibration, never on its own a reason to skip the finding, and an annotated finding at or above the configured re-open threshold is still fixed. (#486)
