# Third-party components

DevFlow itself is MIT-licensed (see [`LICENSE`](../LICENSE), © 2026 Daniel Radman). It also
redistributes the files listed below, which were authored by others and remain under their own
upstream licenses. The full upstream license texts are retained verbatim in this directory.

**Every file listed here has been modified by DevFlow relative to its upstream version.** This
statement is the Apache License 2.0 §4(b) change notice for the Apache-licensed files below; each
of those files additionally carries its own in-file notice. DevFlow's first-party SPDX header (the
`2026 Daniel Radman` line carried by DevFlow-authored source) is deliberately **not** applied over
this third-party content.

These files are redistributed in two ways: the plugin is published from the repository root
(`.claude-plugin/marketplace.json` declares `"source": "./"`), and
`.github/actions/vendor-plugin/vendor-slice.sh` copies the tree — including this `LICENSES/`
directory — into consumer repositories.

## Apache License 2.0

Copyright © Anthropic PBC. Licensed under the Apache License, Version 2.0.

Upstream carries no per-file copyright notices and ships no `NOTICE` file, so §4(c) and §4(d)
impose no retained content; the holder is named here instead, since the Apache appendix boilerplate
in the license texts is unfilled.

| DevFlow path | Upstream project | Upstream license text |
|---|---|---|
| `agents/code-architect.md` | [`feature-dev`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/feature-dev) | [`feature-dev-LICENSE`](feature-dev-LICENSE) |
| `agents/code-explorer.md` | [`feature-dev`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/feature-dev) | [`feature-dev-LICENSE`](feature-dev-LICENSE) |
| `agents/code-reviewer.md` | [`pr-review-toolkit`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/pr-review-toolkit) | [`pr-review-toolkit-LICENSE`](pr-review-toolkit-LICENSE) |
| `agents/comment-analyzer.md` | [`pr-review-toolkit`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/pr-review-toolkit) | [`pr-review-toolkit-LICENSE`](pr-review-toolkit-LICENSE) |
| `agents/pr-test-analyzer.md` | [`pr-review-toolkit`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/pr-review-toolkit) | [`pr-review-toolkit-LICENSE`](pr-review-toolkit-LICENSE) |
| `agents/silent-failure-hunter.md` | [`pr-review-toolkit`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/pr-review-toolkit) | [`pr-review-toolkit-LICENSE`](pr-review-toolkit-LICENSE) |
| `agents/type-design-analyzer.md` | [`pr-review-toolkit`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/pr-review-toolkit) | [`pr-review-toolkit-LICENSE`](pr-review-toolkit-LICENSE) |

Both plugins live in [`anthropics/claude-plugins-official`](https://github.com/anthropics/claude-plugins-official).
`feature-dev-LICENSE` and `pr-review-toolkit-LICENSE` are byte-identical to each other and to that
repository's `LICENSE`; they are kept as two files so each vendored slice has a license text named
for its own upstream project.

## MIT License

Copyright © 2025 Jesse Vincent. Licensed under the MIT License.

| DevFlow path | Upstream project | Upstream license text |
|---|---|---|
| `skills/receiving-code-review/SKILL.md` | [`superpowers`](https://github.com/obra/superpowers) | [`superpowers-LICENSE`](superpowers-LICENSE) |
| `skills/requesting-code-review/SKILL.md` | [`superpowers`](https://github.com/obra/superpowers) | [`superpowers-LICENSE`](superpowers-LICENSE) |
| `skills/requesting-code-review/code-reviewer.md` | [`superpowers`](https://github.com/obra/superpowers) | [`superpowers-LICENSE`](superpowers-LICENSE) |
