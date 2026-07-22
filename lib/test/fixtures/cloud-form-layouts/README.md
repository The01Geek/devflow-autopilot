<!-- SPDX-FileCopyrightText: 2026 Daniel Radman -->
<!-- SPDX-License-Identifier: MIT -->
# cloud-form-layouts fixture corpus (issue #702, AC7)

On-disk seed layouts that the AC7 integration driver
(`lib/test/cloud-form-layout-test.sh`) materializes into throwaway git
checkouts to execute the **cloud helper-invocation form** — the anchor
`${CLAUDE_SKILL_DIR:-<base>}/../../scripts/<helper>` resolving to the
denial-proof repo-relative vendored literal — against two layouts, each with a
**space in the checkout path** and a **shallow detached checkout** represented.

Mirrors `lib/test/fixtures/ghapi-repo-path/exroot`'s committed mini-tree
convention: the seeds are static, and the driver copies them into temp trees to
add the runtime git properties (spaces, shallow, detached) a committed tree
cannot itself carry.

- `source-repo/` — the source-repository workflow layout: the plugin is the
  repo, so the skill lives at `skills/implement/` and its helpers at the
  repo-root `scripts/`. The anchor `skills/implement/../../scripts/<helper>`
  resolves to `scripts/<helper>`.
- `consumer/` — a freshly installed consumer layout: the plugin is vendored
  under `.devflow/vendor/devflow/` (never `.claude/`), so both the skill and
  its helpers live beneath that prefix. The cloud form resolves to
  `.devflow/vendor/devflow/scripts/<helper>`.

Each layout ships one trivial executable helper, `scripts/echo-anchor.sh`
(vendored under `.devflow/vendor/devflow/scripts/` for the consumer), which
prints the sentinel `ANCHOR-OK`. The driver asserts the helper runs (exit 0,
sentinel emitted) when reached through the cloud form inside each materialized
checkout, and that `git rev-parse --show-toplevel` — the repo-root anchoring
the cloud form depends on (#295) — still resolves to the checkout root in a
shallow detached state.

The cloud form itself is a filesystem path join and the driver's
helper-execution assertion does not call git, so that assertion's outcome is not
sensitive to the checkout's git state: the two states are expected to agree on
it. What the shallow-detached variant adds over the spaces variant is the
git-state-sensitive coverage — the shallow and detached self-checks, the
one-reachable-commit (truncated history) check, and the `--show-toplevel`
resolution under that state.
