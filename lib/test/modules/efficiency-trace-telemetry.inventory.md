# Efficiency-trace + telemetry-persistence module inventory

This inventory records the provenance of the focused efficiency-trace and
telemetry-persistence contract module. It is a navigation aid, not a second source
of behavior: `efficiency-trace-telemetry.sh` owns the executable assertions, and the
complete suite calls the same module through `module-harness.sh`'s
`devflow_run_full_suite_module` boundary.

Source baseline: `c2ee6d8a` (`origin/main`).

## What moved

The extracted region was **eight adjacent box-comment sections** in `lib/test/run.sh`
spanning 5,724 lines, plus **one non-contiguous 200-line block** that shares the
region's fixture reader (below). Every section moved whole; nothing inside the
range was left behind.

| Contract group | Former `lib/test/run.sh` section | Representative contract |
| --- | --- | --- |
| Per-run derivation surface | `efficiency-trace.jq / efficiency-trace.sh` | 4-way verdict derivation, marginal-yield line, flag-off writes nothing, graceful degradation when `phase3_dispatched` is absent |
| Persist / self-check | `efficiency-trace.sh --persist / --self-check (issue #80)` | the durable write path, its self-check, and the committed `100755` mode the wrapper depends on |
| Harness cost floor | `harness-side cost floor (issue #475)` | the cost floor the harness is required to record, and its degraded arms |
| Synthesis floor | `efficiency-trace.sh synthesis floor (issue #381)` | shadow-synthesis field set and the `#501` producer/consumer provenance pins |
| Base-ref freshness | `efficiency-trace.sh base-ref freshness (issue #532)` | the freshness operand and its fail-closed arms |
| Telemetry-branch persistence | `telemetry-branch persistence (issue #441)` | `telemetry-branch.sh` tree persistence, collision handling, and CAS retry |
| Push operand | `issue #469: push-operand fail-closed, fetch-before-exclusion, degraded retention` | the push operand's fail-closed selection, fetch-before-exclusion ordering, and degraded retention |
| Cross-workflow relay | `issue #489: cross-workflow telemetry artifact relay` | upload side, trusted pusher, and untrusted-input validation |
| Unavailable-telemetry normalization | `issue #499: unavailable telemetry is explicit and falsy-safe` | established-vs-unavailable normalization, monotonic upgrade, backfill and remote-retry union |

## The non-contiguous `#499` block

The `#499` block did not sit inside the contiguous range — it lived roughly 24,000
lines further down, immediately after the `installer-wiring` module call. It moved
anyway, and not as a judgement call: **every one of its persistence assertions reads
`_et_show`**, the durable-blob reader defined in the `#441` section above it. The two
are one unit, so leaving `#499` behind would have left 23 calls with no callee.
It carries its own banner comment inside the module marking it as non-contiguous in
the source file.

Its boundaries in `lib/test/run.sh` were equally clean: it opened on its own
`# ── issue #499 …` box comment and closed on `rm -rf "$T499_U_ROOT"`, immediately
before the unrelated `#497` shadow prompt-composition pins, which stay in the
monolith.

## What was deliberately left behind

**Four documentation-presence assertions from the `#532` section** stay in
`lib/test/run.sh`, in a commented block beside this module's full-suite call: the
`et-fresh(R14)` residual-window assertion and the three `docs-fetch-scope(R9)`
assertions, all of which `grep` prose out of `docs/efficiency-trace.md`.

The reason is a real gate, not convenience. `lib/test/pin-corpus-lint.py`'s
issue-#948 routing ladder scans every pin site that the merge-base-to-HEAD diff
touches — and a newly added file is entirely "touched", so relocating a site
un-grandfathers it. Three of these four literals resolve into ordinary prose in that
document, and for such a site the ladder passes only when the **delta-gated
adjudication ledger already records the literal as a boundary** *and* the site
carries a `# structural-pin-ok:` declaration naming one of the eight closed
categories. No category honestly describes a documentation-presence pin, and
authorizing a new boundary adjudication requires an evidence argument that a pure
code move does not have. Moving them would therefore have meant either a false
category or a maintainer authorization smuggled into a refactor. Leaving the lines
untouched keeps them outside the classifier's diff and defers the real question —
whether documentation-presence pins should exist at all, per the `CLAUDE.md` bullet on
issues #375, #666 and #810 — to the pass that is draining that population. The fourth
assertion has nothing to gain from separation and is kept beside its siblings.

**The `#442 Critical-1` behavioral arm** stays in `lib/test/run.sh` for a different
and harder reason: it reproduces the bash-3.2 `set -u` empty-array abort under a real
bash 3.x, so it runs on the macOS dev tier and not on Linux CI. A module's emitted
tally is compared for **equality** against the floor in the registry and in the
call-site operand, so a host-conditional arm makes that triple host-dependent — the
module would emit 882 on macOS and 879 on Linux and one of the two would always read
as a regression. `module_host_capability_skip` is the harness's answer to exactly
this shape and would credit the difference, but at the cost of a permanent nonempty
skip tally on every CI run, and a nonempty skip tally is never a clean pass (#456).
The monolith's tally carries no floor, so keeping the arm there leaves both the module
triple and the CI skip tally clean. Its `_et_on_branch` reader is **not** copied into
`run.sh`: the one-line `git cat-file -e` that helper wraps is inlined at the two call
sites instead, so no helper gains a second definition. The *static* half of the same
guard — that `telemetry-branch.sh` carries no bare `"${arr[@]}"` expansion, which is
what keeps Linux CI honest about the defect — is host-independent and moved with the
region.

Two other relocated sites *do* have an honest category and carry a new
`# structural-pin-ok:` declaration in this module:

- the `#426 T1` slice-fence pin — `cross-file-phase-contract`: the literal is the
  review engine's Phase 1.1 command fence, re-parsed a few lines later by this
  module's own `AWK_PROG` extraction, so it is a machine-consumed contract between
  the phase file and this driver;
- the `#489` per-entry unreadable-reject pin — `helper-contract`: the literal is
  matched against the validator's real captured stderr, a rendered executable
  surface rather than source wording.

The `#161 git_sandbox` mutation-proof block — which exercises the helper this module
uses ~160 times — also stays in the monolith, but on unrelated grounds: it proves the
*helper's* fail-closed contract, not this module's subject matter, and it was never
inside either extracted range.

Label attribution for the moved sections is recorded in
`lib/test/modules/coverage-map.json`. Thirteen labels moved wholly and name this
module as owner; seven more (`#170`, `#426`, `#502`, `#530`, `#539`, `#541`, `#745`)
are asserted both inside and outside the moved ranges and correctly stay
`unmodularized`. Label `#431` is now carried by two modules — this one and
`experiment-records` — and is asserted nowhere in `lib/test/run.sh`; its note records
that split.

## Rewrites performed during extraction

The move is otherwise byte-faithful. Two mechanical 1:1 renames onto the namespaced
module pin API, with literals and targets unchanged:

- every `assert_pin_unique` call became `devflow_module_pin_unique` (20 sites);
- every `pin_count` call became `devflow_module_pin_count` (14 sites).

`git_sandbox` and `probe_tmp` need no rename: both live in
`lib/test/module-harness.sh`, which every runner sources before any module body.

Four `lib/test/run.sh` globals are re-derived in the module header rather than
inherited, since a module cannot read a monolith global:

- `REPO_ROOT`, derived from `LIB` but spelled `$LIB/..` — deliberately **not** the
  monolith's `$(cd "$LIB/.." && pwd)` form — so `pin-corpus-lint.py`'s path resolver,
  which understands a `$LIB/relative` assignment but bails on a command substitution,
  can resolve every `REPO_ROOT`-derived pin target.
- `REVIEW_BUNDLE` (and its alias `ST_REV`), the concatenated review-engine bundle:
  thin root plus every `skills/review/phases/*.md`.
- `MAXI_BUNDLE` (and its alias `MAXI_SKILL`), the concatenated review-and-fix bundle:
  thin root plus every `skills/review-and-fix/references/*.md`.

Both bundles are assembled with `devflow_module_build_bundle`, the shared fail-closed
builder, so a missing, empty or unreadable member lands in the tally as a named RED
assertion instead of silently shrinking the bundle and turning the survival pins
vacuous. Membership is derived from the shipped tree by glob, never transcribed, so a
reference added to either engine joins the bundle with no lockstep edit here. The
builder emits no assertion on the happy path, which is what keeps the extraction
assertion-conserving: the module's tally is exactly the assertions that left
`lib/test/run.sh`.

## Floor

The assertion floor is recorded once, in
`scripts/workflow-flight-recorder-registry.json`, and enforced on every run by
`lib/test/run-module.sh`; `test_module_runner.py` reconciles that floor against the
`lib/test/run.sh` call-site literal and asserts the module runs green through the
real runner. This inventory deliberately states no exact assertion count — the
registry is the single source, so a count copied here could drift out of it silently.

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global, so deleting this module cannot also
delete the checks that prove it is selected and executed.
