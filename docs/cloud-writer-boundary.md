# Cloud-writer helper leading-token boundary — decision record

Issue #701 (deferred from #678, itself from #650). Resolves the anchor-convention
conflict that made AC2 and AC3 unimplementable as literally worded, and records
how they were discharged.

## The conflict

AC2 asked that a bundled-helper cloud command be **emitted with a literal
`.devflow/vendor/devflow/scripts/…` leading token** and its local twin retain the
portable anchor. AC3 asked for a **raw-token guard over source that rejects
unexpanded anchors**. Both, taken literally, collide with two binding
conventions:

- **Issue #275 (portable anchor).** Every legitimate helper call site keeps the
  portable `${CLAUDE_SKILL_DIR:-…}/../../scripts/x` anchor **in source**, because
  `${CLAUDE_SKILL_DIR}` is empty on non-Claude-Code runners; the agent resolves it
  to the vendored literal only when it emits the command. Removing the anchor from
  source breaks that portability contract.
- **Issue #455.** Row I1 — the unexpanded anchor as a leading token — was declared
  "not lint-pinnable on either tier … so it stays prose-discipline", precisely
  because the anchor is the sanctioned *source* form.

Satisfying AC2/AC3 by writing a second, cloud-only fence per call site would also
duplicate the shipped-default review-bundle surface, colliding with the word
ceiling (`docs/review-bundle-budget.md`).

## The decision — restate against the emission-time surface

The issue's Desired Behavior offered two options: amend the anchor convention so a
mechanically-checkable cloud form exists in source, **or** restate AC2/AC3 against
the emission-time surface they actually govern. This run (autonomous
`/devflow:implement`, no operator present) chose the **second** option, because the
first breaks #275 and the word ceiling.

Key observation: `lib/test/extract-command-heads.py`'s `_ANCHOR`/`_normalize`
already reduce the well-formed portable source anchor to the exact vendored
literal `.devflow/vendor/devflow/scripts/x` — the same string the cloud allowlist
grants and the cloud runner emits. So **the single anchored source line IS the
cloud call-site form after emission**; no duplicate fence is needed.

- **AC2 (restated).** The cloud call-site form is the emission-time normalized
  leading token, which the guard certifies to be the vendored literal for every
  cloud-reached bundled-helper command. The "local command" is the same source
  line with the anchor unresolved. One source, both tiers, no duplication.
- **AC3 (restated).** `check_helper_boundary` (in `lib/test/cloud_writer_contract.py`,
  built on `extract-command-heads.py`'s `helper_boundary_violations`) requires the
  vendored helper path to be the first executable token of every cloud-reached
  fenced command that names a per-helper-granted bundled helper. It rejects, by
  classified reason:
  - `unexpanded-anchor` — a malformed anchor that does not normalize to the
    vendored literal;
  - `absolute-path` — an absolute helper path;
  - `repo-root-path` — a repo-root `scripts/…`/`lib/…` helper path;
  - `helper-not-leading` — a helper-shaped path under any other prefix;
  - `launcher-prefixed:<head>` — a helper behind a granted launcher head
    (`env`/`xargs`/interpreter/process-wrapper), which would match the launcher's
    broad grant instead of the per-helper vendored grant.

  The launcher table is **generated from the profile's parsed grants** (∩
  `LAUNCHER_HEADS`), read before the wrapper normalization `extract-command-heads.py`
  applies, so a granted wrapper head cannot slip a helper past the boundary. This
  closes AC9's documented scope-limit (i) (the interpreter/wrapper blind spot) on
  the call-site side.

## Scope and non-goals

- The guard governs only helpers that carry a **per-helper vendored grant**
  (`REQUIRED_HELPER_HEADS[profile]`). A helper whose sanctioned cloud form is
  `python3 <helper>` via a granted interpreter (e.g. `refresh-pr-run-link.py`,
  piped through stdin) is deliberately **not** governed — it has no per-helper
  grant to bypass.
- A helper named only as a **command argument** (an `echo` breadcrumb, the outer
  statement of a `VAR=$(helper …)` capture) is not a violation; the guard descends
  into `$(…)` and checks each command-position unit, so the capture body's helper
  head is checked in its own right.
- The guard is a desk/CI-time check driven from `lib/test/test_python_scripts.py`
  (the required `lib + python tests` job); it renders no manifest and ships no
  runtime footprint.

## Enforcement completeness (AC8, deferred half)

`test_python_scripts.py`'s #701 block plants one copy-based mutation per boundary
reason class and one per **granted launcher head** (generated from the parsed
launcher table), observing each RED one at a time through `check_helper_boundary`'s
own per-asset loop. The path-reason set is reconciled against the reasons
`_classify_boundary` can emit, so a new reason added to the classifier without a
control turns the suite RED. The launcher set is non-vacuous and equals the
profile's granted heads ∩ `LAUNCHER_HEADS`.
