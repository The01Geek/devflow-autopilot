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

## What these fixtures do and do not guard

These are self-contained mock trees, and the driver passes each layout's skill
base and vendored-literal helper path as a pair that is consistent with the
other by construction. So what they prove is the **layout shape**: a skill base
two components below the directory that also contains `scripts/`, joined with
`../../scripts/<helper>`, resolves to and executes that layout's helper — in a
spaced checkout and in a shallow detached one. That containing directory is not
the same in both layouts: it is the checkout root for `source-repo`, and the
vendored prefix `.devflow/vendor/devflow/` for `consumer`, whose skill base is
five components below the checkout root. They do **not**, by themselves, guard
the real shipped `skills/**` ↔ `scripts/` offset: relocating the real tree would
leave these fixtures green. The driver's separate `real shipped layout` block is
the narrow guard for that residual, over the **source-repo** layout only — it
asserts every tracked `skills/*/SKILL.md` still sits two components below the
repo root and that a repo-root `scripts/` exists. The consumer layout is that
same tree copied wholesale under `.devflow/vendor/devflow/` by `install.sh`,
which carries the offset along with it; nothing checks that copy.

The cloud form itself is a filesystem path join and the driver's
helper-execution assertion does not call git, so that assertion's outcome is not
sensitive to the checkout's git state: the two states are expected to agree on
it. What the shallow-detached variant adds over the spaces variant is the
git-state-sensitive coverage — the shallow and detached self-checks, the
one-reachable-commit (truncated history) check, and the `--show-toplevel`
resolution under that state.
