---
bump: patch
---

### Fixed

- **The stale counted-prose lint now examines only comment/prose lines.** `scripts/stale-prose-lint.py` was grading *every* diff-added line of every path, so a line of code that merely contained claim-shaped text — a shell fixture string, an assertion name — was graded exactly like a real header. That made the lint fire on its own test corpus (14 STALE rows against DevFlow's own branch diff, all of them fixtures), which would have cost a spurious Important finding per row on any PR touching them, and grew with every fixture added. A claim is prose: the helper now decides per file type which lines can carry one (markdown-family prose outside fenced blocks; `#` comments; `//` comments and `/* … */` interiors; Python `#` comments plus genuine docstrings, resolved with `ast` so claim-shaped string literals in tests are not mistaken for prose), and the same predicate scopes **R4's permit referent**, so a code line can neither raise a claim nor contradict one. **An unrecognised file type fails open** — every added line is examined exactly as before, with a stderr breadcrumb — so a consumer repo in a language DevFlow has not listed degrades to the status quo, never to silent no-checking. This restores the scope issue #423 specified. (#434)
