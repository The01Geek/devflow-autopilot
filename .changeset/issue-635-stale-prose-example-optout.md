---
bump: patch
type: Fixed
---

- **`stale-prose-lint`: prose that documents a claim shape is no longer graded as a claim of that shape.** A design-record example, a fixture-comment idiom, or engine docs describing a rule class were graded as real R1–R4 claims and could gate a false-positive `STALE` against DevFlow's own repo. A prose/comment line may now carry an explicit, language-agnostic opt-out marker (`stale-prose-lint: example`) that skips all rule recognition for that one line. R4's single-backtick operator referent is untouched, so genuine deny-absolute claims still gate. (#635)
