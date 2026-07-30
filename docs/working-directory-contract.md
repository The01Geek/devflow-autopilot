# PRFlow working-directory contract

Every PRFlow bundled-helper invocation on the cloud tiers is a **repo-relative
literal** — `.devflow/vendor/devflow/scripts/…` (and `.devflow/vendor/devflow/lib/…`),
or the repo-root `scripts/…` / `lib/…` form in a self-repo checkout — because that
is the only form the harness permission matcher grants (see
[`docs/cloud-allowlist.md`](cloud-allowlist.md)). A repo-relative literal only
resolves if the shell's working directory is the repository root. That makes the
working directory a **load-bearing precondition** for the whole engine, and this
page is the single canonical statement of what that precondition is and where it
holds.

The rule this page exists to state, up front: **no PRFlow surface emits a leading
`cd`.** A statement whose first token is `cd` (a "leading `cd`") moves the shell's
working directory, and because the Bash tool's working directory **persists across
calls** (see below), every later repo-relative helper then resolves against the
wrong directory and fails — `rc 127` for a helper path, `rc 2` for an `awk`/`jq`
over a cached file. The permitted alternative is the one the matcher already
grants: **the repo-relative vendored literal as the command's leading token**, with
any absolute path confined to **argument position** (a helper path is never behind
a `cd`, a `VAR=value` prefix, or a `bash <path>` wrapper).

## Cloud tiers — the run starts at the workspace root, and cwd persists

On the cloud tiers (`devflow-runner.yml`, `devflow.yml`, `devflow-implement.yml`):

- `actions/checkout` places the run at the **workspace root**, and no PRFlow job
  overrides it — there is no `working-directory:` on any step and no job `cd`s. So
  the run **begins at the repository root**, which is the directory every
  repo-relative helper literal resolves against.
- The Bash tool's **working directory persists across calls**: a `cd` in one Bash
  call changes the directory seen by the *next* Bash call, not just the current
  one. This is why a single stray leading `cd` corrupts every later helper
  invocation in the run rather than just its own statement, and why the no-`cd`
  rule is absolute rather than advisory.

That pairing — start-at-root plus persistent cwd — is the whole reason every
granted helper literal is repo-relative with **no re-anchored form the matcher
accepts**. There is no cloud-permitted spelling that would let a helper resolve
from some other directory, so the only safe posture is to never leave the root.

## Local and interactive tier — no working-directory guarantee

The local and interactive tier carries **no** such guarantee. A consumer invokes
PRFlow from any directory, on Windows, macOS, or Linux, across several runners
(Claude Code, Copilot CLI, Cursor, Codex CLI, Gemini CLI). Nothing pins the shell
to the repository root. PRFlow therefore does not depend on cwd on this tier; it
**re-anchors** instead, through two mechanisms:

- **`git rev-parse --show-toplevel` resolution used by the `.devflow/` readers.**
  The six `.devflow/` config/prompt-extension readers (`config-get.sh`,
  `workpad.py`'s marker read, `load-prompt-extension.sh`,
  `match-deferrals.py`, `match-lint-adjudications.py`, `render-audit-prompt.py`)
  resolve the default `.devflow/` path anchored to the **git repository root**
  (`git rev-parse --show-toplevel`, falling back to `pwd`/`Path.cwd()`), so a skill
  run from a subdirectory still loads the consumer's root config instead of
  silently missing it.
- **`BASH_SOURCE` self-anchoring used by `scripts/*.sh` helpers.** A shell helper
  that must reach a sibling file resolves its own directory from `${BASH_SOURCE[0]}`
  rather than assuming cwd, so it works regardless of the directory it is invoked
  from.

Because these mechanisms exist, a local/interactive helper does not need the
working directory to be the repository root — but the no-`cd` authoring rule still
holds, so that a surface authored once reads correctly on the cloud tiers it is
vendored to.

## Why the rule is an authoring rule, not a matcher claim

The no-`cd` rule is stated as an **authoring rule** — "no PRFlow surface emits a
leading `cd`" — and **not** as a claim that a matcher refuses one. The PR #847
review incident (run 30222310785) recorded a leading `cd` **executing** on the
review tier, where `Bash(cd:*)` is already ungranted, so an ungranted `cd` head
does not imply a refused statement. The affordance is instead removed at the
authoring layer: `Bash(cd:*)` is not granted in any profile, and
`lib/test/extract-command-shapes.py`'s implement-profile finder emits an **`IR4`**
hit for a fenced statement whose head is `cd`, so a `cd` authored into a scanned
prompt surface fails at the desk. That desk lint scans only authored ` ```bash `
fences, so it governs what a future author writes into a prompt surface — it does
**not** catch a `cd` a model composes at runtime (issue #805 owns that mechanism).

## Pointers

- [`docs/cloud-allowlist.md`](cloud-allowlist.md) — the matcher-shape evidence,
  the granted-literal forms, and the `cd` status per tier.
- `CLAUDE.md` carries a short non-authoritative summary paired with a pointer to
  this page.
