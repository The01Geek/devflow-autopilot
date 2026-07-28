---
bump: patch
type: Fixed
---

- **Restore the Apache-2.0 §4(b) change notice on the seven vendored Anthropic agents.** All
  seven agents DevFlow vendors from Anthropic's `feature-dev` and `pr-review-toolkit` plugins are
  modified relative to upstream, but carried no notice stating so after the per-file attribution
  blocks were removed. Each now carries a four-line notice naming its upstream plugin, the
  Apache-2.0 license text in `LICENSES/`, and the fact that DevFlow modified it. A new
  `LICENSES/README.md` indexes every vendored file against its upstream project, license, and
  copyright holder — including the MIT-licensed `superpowers` skills, whose holder was previously
  named only in the license boilerplate — and the README's License section points at it.
