# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable regenerate-artifacts contract module (issue #619).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first (which defines the namespaced module pin API:
# devflow_module_pin_count / devflow_module_pin_unique / devflow_module_pin_present /
# devflow_module_pin_red_under). This module uses assert_eq plus the `_ra_*`
# domain-private helpers defined below — it references NO monolith helper. They are
# deliberately not enumerated here: an exact list is a mirror-fact that goes stale on
# the next helper added, and the definitions below are the authoritative set.
# The module owns its private fixture root and cleanup; it never invokes the runner
# or the full-suite boundary. The inventory in regenerate-artifacts.inventory.md
# records the module's provenance. Modules may not self-skip.
# The `trap _ra_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling. Do not source this module directly in a runner's
# top-level shell without restoring the trap.
#
# EVERY planted-drift assertion runs against a temp fixture root, never the live
# checkout, and each fixture-root assertion additionally asserts the live tree's
# scripts/devflow-cloud-writer-contract.json is byte-unchanged. Live-tree confinement
# is asserted, not assumed from the generators' current __file__-based root
# resolution: an interrupted live-tree mutate-and-restore would leave a
# self-consistent corrupted asset+manifest pair on disk that the issue-543 verify
# gate would then certify green.

RA_HELPER="$LIB/test/regenerate-artifacts.py"
RA_REPO="$LIB/.."
RA_CAPMUT="$LIB/test/cap-mutate.py"
RA_LIVE_MANIFEST="$RA_REPO/scripts/devflow-cloud-writer-contract.json"

_ra_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/devflow-regenerate-artifacts.XXXXXX")" || {
  printf 'could not allocate regenerate-artifacts fixture\n' >&2
  return 1
}
_ra_cleanup() {
  rm -rf "$_ra_tmp_root"
}
trap _ra_cleanup EXIT

# The live manifest's bytes, captured once before any fixture run. Every fixture
# assertion re-compares against this so a helper that escaped its target root would
# be caught by the very next assertion rather than shipping green.
_ra_live_before="$(cat "$RA_LIVE_MANIFEST" 2>/dev/null)"
# Non-emptiness is asserted, not assumed: an unreadable or absent live manifest would
# make _ra_live_before empty, and every _ra_live_unchanged guard below would then
# compare "" to "" and pass vacuously — every confinement assertion in this module
# failing open at once, on exactly the broken tree they exist to catch.
case "$_ra_live_before" in
  '') assert_eq "#619 the live manifest baseline is non-empty (confinement guards are live)" yes \
        "no(empty — $RA_LIVE_MANIFEST unreadable or absent; every live-unchanged guard would be vacuous)" ;;
  *)  assert_eq "#619 the live manifest baseline is non-empty (confinement guards are live)" yes yes ;;
esac
# One byte-compare assertion used by every "these bytes must not have moved" check, so
# the shape exists once rather than being re-spelled per call site.
_ra_same() {  # name expected actual fail-detail
  if [ "$2" = "$3" ]; then assert_eq "$1" yes yes; else assert_eq "$1" yes "no($4)"; fi
}
_ra_live_unchanged() {  # name
  _ra_same "$1" "$_ra_live_before" "$(cat "$RA_LIVE_MANIFEST" 2>/dev/null)" \
    "live checkout manifest was mutated by a fixture run"
}

# ────────────────────────────────────────────────────────────────────────────
echo "#619 batched generated-artifact regeneration pass (lib/test/regenerate-artifacts.py)"
# ────────────────────────────────────────────────────────────────────────────

# One pristine fixture is built once and copied per assertion: each copy is a full
# repository image (the generators resolve their roots from __file__ or an argv root,
# so a partial tree would exercise the wrong closure), and rebuilding it per
# assertion would dominate the module's runtime.
# Every top-level tracked entry is copied, not a hand-picked subset: the census reads
# CLAUDE.md and agents/, the cloud-writer closure reads skills/ and scripts/, and a
# subset that misses one makes the *pristine* fixture drift, which would silently
# invalidate every "no other row drifted" premise in this module.
_ra_pristine="$_ra_tmp_root/pristine"
mkdir -p "$_ra_pristine"
# The top-level name is taken with bash parameter expansion, never `cut`/`sort` — a
# non-preflight PATH tool must not decide WHICH files get copied (CLAUDE.md's
# un-guaranteed-tool rule): a missing tool would yield an empty entry list and a
# hollow fixture. git is preflight-guaranteed.
_ra_seen=" "
while IFS= read -r _path; do
  [ -n "$_path" ] || continue
  _entry="${_path%%/*}"
  case "$_ra_seen" in *" $_entry "*) continue ;; esac
  _ra_seen="$_ra_seen$_entry "
  cp -R "$RA_REPO/$_entry" "$_ra_pristine/$_entry" 2>/dev/null
done < <(cd "$RA_REPO" && git ls-files)
# The loop derives entry NAMES from git ls-files but copies whole directories, so
# untracked build caches ride along into the image and then into every arm copy — and
# into the fixture's own `git add -A`, inflating the git legs the budget row measures.
# Prune them once, here, rather than 8 times downstream.
find "$_ra_pristine" \( -name __pycache__ -o -name .ruff_cache \) -type d -prune -exec rm -rf {} + 2>/dev/null || :
rm -rf "$_ra_pristine/.devflow/tmp" 2>/dev/null || :
# A fixture must be a git repository: the budget row derives its change set with git,
# and coverage_map_guard.py enumerates the tracked surface with `git ls-files`. The
# synthetic origin/main ref is what makes the merge-base leg resolvable; the A6
# assertion below deliberately removes it to drive the `unestablished` arm.
(
  cd "$_ra_pristine" || exit 1
  git init -q . 2>/dev/null
  git config user.email devflow@example.invalid
  git config user.name devflow
  git add -A 2>/dev/null
  git commit -q -m fixture 2>/dev/null
  git update-ref refs/remotes/origin/main HEAD 2>/dev/null
) >/dev/null 2>&1

_ra_fixture() {  # <dest>
  cp -R "$_ra_pristine" "$1"
}

# Re-reconcile the NON-budget rows in a fixture after planting a review-bundle change.
# Every watch-list member is also either a prompt-mass census row or a cloud-writer
# closure asset, so any edit that moves the budget row moves one of those too. Without
# this the budget assertions below would be vacuous: the run's exit 1 would be
# attributable to the manifest or the census, not to the budget row under test.
_ra_reconcile() {  # <root>
  # rc is CHECKED, not swallowed: if a reconcile step silently fails, the row it was
  # meant to quiet stays drifted and the budget assertion downstream becomes
  # attributable to that row instead of the one under test — a vacuous pass wearing a
  # green tick. Surface it as a named failure rather than letting the caller's
  # assertion misreport what it measured.
  if ! ( cd "$1" && python3 lib/test/cloud_writer_contract.py generate >/dev/null 2>&1 &&
         python3 lib/test/prompt-mass-census.py --write-baseline >.ra-baseline.tmp 2>/dev/null &&
         mv .ra-baseline.tmp lib/test/prompt-mass-baseline.json ) >/dev/null 2>&1; then
    assert_eq "#619 fixture reconcile succeeded for ${1##*/}" yes \
      "no(cloud-writer generate or census --write-baseline failed; downstream budget assertions would be misattributed)"
  fi
}

# Run the helper against a target root, capturing combined output and rc into
# per-fixture files. The helper is invoked by its LIVE path with --repo-root pointed
# at the fixture, which is exactly how the suite drives its failure arms.
_ra_run() {  # <root>
  python3 "$RA_HELPER" --repo-root "$1" >"$1/.ra.out" 2>&1
  printf '%s\n' "$?" >"$1/.ra.rc"
}
_ra_rc() { cat "$1/.ra.rc"; }
_ra_has() {  # name root substring
  local n
  n="$(devflow_module_pin_count "$3" "$2/.ra.out")"
  case "$n" in
    ''|*[!0-9]*) assert_eq "$1" yes "no(count unestablished for '$3')"; return 0 ;;
  esac
  if [ "$n" -ge 1 ]; then assert_eq "$1" yes yes
  else assert_eq "$1" yes "no('$3' absent; output: $(tr '\n' '|' <"$2/.ra.out"))"; fi
}

# The registry's row names, declared ONCE and consumed by both the A1 clean-line loop
# and the A4 --list loop — adding a row must not mean editing two lists.
RA_ROW_NAMES="cloud-writer-manifest capability-profile-literals prompt-mass-baseline review-bundle-budget review-and-fix-budget coverage-map-ratchet"

# ── A1 — clean-tree run: exit 0 with a per-row clean line for every row ──────
# Run against a PRISTINE FIXTURE, never the live checkout. Two reasons, both real:
# (1) the mechanical row WRITES scripts/devflow-cloud-writer-contract.json, so a live
#     run would mutate a tracked file in the developer's tree as a test side effect —
#     invisible on a reconciled tree, a silent regeneration on exactly the drifted tree
#     this helper exists to detect;
# (2) the live tree's cleanliness is a property of whatever branch the suite runs on,
#     not of the helper — a branch legitimately editing review-bundle prose makes the
#     budget row emit INFO (or JUDGMENT), so a live per-row `clean` assertion would go
#     RED for reasons unrelated to the code under test.
# The fixture is committed with origin/main == HEAD, so every row is clean BY
# CONSTRUCTION. The live tree keeps its non-mutating coverage in A4 (`--list` launches
# no row) and in the suite's own artifact gates.
RA_A1="$_ra_tmp_root/a1"; _ra_fixture "$RA_A1"
RA_CLEAN_OUT="$(python3 "$RA_HELPER" --repo-root "$RA_A1" 2>&1)"; RA_CLEAN_RC=$?
assert_eq "#619 A1 clean-tree run exits 0" "0" "$RA_CLEAN_RC"
for _row in $RA_ROW_NAMES; do
  case "$RA_CLEAN_OUT" in
    *"[$_row] clean"*) assert_eq "#619 A1 clean-tree row reports clean: $_row" yes yes ;;
    *) assert_eq "#619 A1 clean-tree row reports clean: $_row" yes "no(no clean line for $_row)" ;;
  esac
done
_ra_live_unchanged "#619 A1 live manifest byte-unchanged after the clean run"

# ── A2 — mechanical drift against a fixture: regenerates, exits 1, idempotent ─
RA_A2="$_ra_tmp_root/a2"; _ra_fixture "$RA_A2"
# Corrupt the checked-in manifest itself so `generate` rewrites it. Mutating a
# reached skill *asset* would drift the manifest too, but every such asset is also a
# prompt-mass census row, so the census row would drift in the same fixture and the
# idempotency assertion below could never reach exit 0 — this isolates the mechanical
# row. The asset closure stays intact, so this is manifest drift (the exit-0-with-
# changed-bytes arm), not a closure error.
printf '{"corrupted": true}\n' > "$RA_A2/scripts/devflow-cloud-writer-contract.json"
RA_A2_BEFORE="$(cat "$RA_A2/scripts/devflow-cloud-writer-contract.json")"
_ra_run "$RA_A2"
RA_A2_AFTER="$(cat "$RA_A2/scripts/devflow-cloud-writer-contract.json")"
assert_eq "#619 A2 planted mechanical drift exits 1" "1" "$(_ra_rc "$RA_A2")"
_ra_has "#619 A2 reports the regenerated artifact by name" "$RA_A2" \
  "REGENERATED scripts/devflow-cloud-writer-contract.json"
# Inverted sense (these bytes MUST have moved), so it asserts against a sentinel rather
# than adding a second comparator.
_ra_same "#619 A2 the fixture manifest bytes changed" changed \
  "$([ "$RA_A2_BEFORE" != "$RA_A2_AFTER" ] && echo changed || echo unchanged)" \
  "the regeneration left the fixture manifest byte-identical"
# Idempotency: a second run over the now-regenerated fixture is clean.
_ra_run "$RA_A2"
assert_eq "#619 A2 second run over the regenerated fixture exits 0" "0" "$(_ra_rc "$RA_A2")"
_ra_live_unchanged "#619 A2 live manifest byte-unchanged after the fixture drift run"

# ── A2b — closure error routes to an exit-1-forcing JUDGMENT, not exit 2 ─────
RA_A2B="$_ra_tmp_root/a2b"; _ra_fixture "$RA_A2B"
# Delete a reached asset: check_closure() then returns 1 with cloud-writer-contract:
# prefixed lines — exactly what a loop's rename/delete edits produce. The agent must
# be steered to reconcile the closure, never to chase an infrastructure diagnosis.
rm -f "$RA_A2B/skills/implement/phases/phase-4-documentation.md"
_ra_run "$RA_A2B"
assert_eq "#619 A2b closure error exits 1 (a judgment item, not infrastructure)" "1" "$(_ra_rc "$RA_A2B")"
_ra_has "#619 A2b closure error prints the generator output verbatim" "$RA_A2B" "cloud-writer-contract:"
_ra_has "#619 A2b closure error names the closure data as the governing policy" "$RA_A2B" \
  "ROOTS / DISPATCH_EDGES / SKILL_ASSETS"
_ra_has "#619 A2b closure error is not misattributed to infrastructure" "$RA_A2B" \
  "this is a closure error, not an "
_ra_live_unchanged "#619 A2b live manifest byte-unchanged after the closure-error run"

# ── A2c — a marker-less exit 1 (a traceback) routes to exit 2, never a judgment ─
RA_A2C="$_ra_tmp_root/a2c"; _ra_fixture "$RA_A2C"
printf 'import sys\nprint("Traceback (most recent call last): boom", file=sys.stderr)\nsys.exit(1)\n' \
  > "$RA_A2C/lib/test/cloud_writer_contract.py"
_ra_run "$RA_A2C"
assert_eq "#619 A2c marker-less exit 1 routes to the infrastructure state (exit 2)" "2" "$(_ra_rc "$RA_A2C")"
_ra_has "#619 A2c marker-less exit 1 names the missing marker" "$RA_A2C" \
  "no \`cloud-writer-contract:\` marker"
_ra_live_unchanged "#619 A2c live manifest byte-unchanged after the traceback run"

# ── A3 — two drifts, ONE invocation: both judgment items, write scope honored ─
RA_A3="$_ra_tmp_root/a3"; _ra_fixture "$RA_A3"
python3 "$RA_CAPMUT" "$RA_A3" profiles-extra-key >/dev/null 2>&1 \
  || assert_eq "#619 A3 planted capability drift applied" yes "no(cap-mutate failed)"
printf '\n<!-- #619 census drift -->\n' >> "$RA_A3/.devflow/prompt-extensions/implement.md"
# Byte snapshots of every judgment-gated artifact: the helper must not write ANY of
# them. This is the write-scope guarantee stated as a negative assertion, taken with
# the suppressed input (planted drift) present rather than on a clean tree.
RA_A3_WF="$(cat "$RA_A3/.github/workflows/devflow-runner.yml" "$RA_A3/.github/workflows/devflow.yml" \
            "$RA_A3/.github/workflows/devflow-implement.yml" "$RA_A3/.github/workflows/matcher-probe.yml")"
RA_A3_LOCK="$(cat "$RA_A3/lib/review-profile.tokens")"
RA_A3_BASE="$(cat "$RA_A3/lib/test/prompt-mass-baseline.json")"
RA_A3_BUDGET="$(cat "$RA_A3/docs/review-bundle-budget.md")"
RA_A3_RAFBUDGET="$(cat "$RA_A3/docs/review-and-fix-budget.md")"
RA_A3_COVMAP="$(cat "$RA_A3/lib/test/modules/coverage-map.json")"
_ra_run "$RA_A3"
assert_eq "#619 A3 combined capability+census drift exits 1" "1" "$(_ra_rc "$RA_A3")"
_ra_has "#619 A3 one invocation reports the capability judgment item" "$RA_A3" \
  "[capability-profile-literals] JUDGMENT"
_ra_has "#619 A3 one invocation reports the census judgment item" "$RA_A3" \
  "[prompt-mass-baseline] JUDGMENT"
_ra_has "#619 A3 the capability item names its governing policy" "$RA_A3" \
  "update lib/review-profile.tokens when the resolved review list widens"
_ra_has "#619 A3 the census item names its governing policy" "$RA_A3" \
  "the mandatory-byte census section of .devflow/prompt-extensions/implement.md"
_ra_cmp() {  # name expected root-relative-file
  _ra_same "$1" "$2" "$(cat "$RA_A3/$3")" "$3 was written by a judgment row"
}
RA_A3_WF_NOW="$(cat "$RA_A3/.github/workflows/devflow-runner.yml" "$RA_A3/.github/workflows/devflow.yml" \
                "$RA_A3/.github/workflows/devflow-implement.yml" "$RA_A3/.github/workflows/matcher-probe.yml")"
_ra_same "#619 A3 write scope: the four workflow files are byte-unchanged" \
  "$RA_A3_WF" "$RA_A3_WF_NOW" "a workflow was written by a judgment row"
_ra_cmp "#619 A3 write scope: lib/review-profile.tokens is byte-unchanged" "$RA_A3_LOCK" lib/review-profile.tokens
_ra_cmp "#619 A3 write scope: the prompt-mass baseline is byte-unchanged" "$RA_A3_BASE" lib/test/prompt-mass-baseline.json
_ra_cmp "#619 A3 write scope: the budget record is byte-unchanged" "$RA_A3_BUDGET" docs/review-bundle-budget.md
# #624: the sibling budget row is a judgment row like every other, so its record is
# equally in the never-written set — omitting it would leave the newly-registered row's
# write scope unasserted, the same gap the coverage map's line below closed.
_ra_cmp "#624 A3 write scope: the review-and-fix budget record is byte-unchanged" "$RA_A3_RAFBUDGET" docs/review-and-fix-budget.md
# The coverage-map ratchet is a judgment row like every other, so its artifact is
# equally in the never-written set — omitting it left one registered judgment row's
# write scope unasserted.
_ra_cmp "#619 A3 write scope: the coverage map is byte-unchanged" "$RA_A3_COVMAP" lib/test/modules/coverage-map.json
_ra_live_unchanged "#619 A3 live manifest byte-unchanged after the combined-drift run"

# ── A4 — --list names every artifact and exposes the real bundle membership ──
RA_LIST="$(python3 "$RA_HELPER" --list 2>&1)"; RA_LIST_RC=$?
assert_eq "#619 A4 --list exits 0" "0" "$RA_LIST_RC"
for _row in $RA_ROW_NAMES; do
  case "$RA_LIST" in
    *"artifact	$_row	"*) assert_eq "#619 A4 --list names artifact: $_row" yes yes ;;
    *) assert_eq "#619 A4 --list names artifact: $_row" yes "no($_row absent from --list)" ;;
  esac
done
# Each budget row's watch list is compared against the DISK-derived bundle member set,
# never against the monolith's $REVIEW_ROOT/$REVIEW_PHASE_STEMS/$RB_EXT or $RAF_ROOT_W/
# $RAF_EXT_W variables — those are unset under standalone run-module.sh execution, which
# would make the comparison vacuous exactly where the module is run alone. Each disk set
# is already coupled to what the monolith measures: the review bundle by run.sh's
# issue-529 pin that phases/ matches REVIEW_PHASE_STEMS, and the review-and-fix bundle by
# the #530 block's RAF_EXPECTED_REFS both-ways pin on references/*.md — so both couplings
# are transitive.
#
# Since issue #624 the helper's budget-watch lines carry the ROW NAME as their second
# field, so each row's list is extracted by its own attributed prefix. Extracting by the
# bare `budget-watch` prefix would concatenate both rows' members into one blob, and the
# equality below would then still pass if a member migrated from one row to the other.
# `mv` is not preflight-guaranteed (lib/preflight.sh covers git/gh/jq/python3/PyYAML only),
# and an unchecked fixture rename fails silently: the arm then runs against a tree that does
# NOT have the shape under test. Several arms currently fail closed only because their
# expected counts happen to invert on a failed rename — a property of the chosen values, not
# of the code, which a later polarity change would quietly turn into a vacuous pass. Assert
# the rename instead of relying on that.
_ra_mv() {  # arm-label src dst
  # Capture stderr rather than discarding it: rc alone turns the arm RED (the load-bearing
  # property) but collapses several distinct causes — `mv` absent from PATH, a source the
  # fixture never materialized, an unwritable destination — into one message, leaving a
  # maintainer to re-derive the cause by hand. That is the same debugging tax the sibling
  # `--list` guards were reworked to remove. The `tr` is cosmetic-only (the assertion is
  # already failing when it runs), so its absence degrades the message, never the verdict.
  if mv "$2" "$3" 2>"$_ra_tmp_root/.ra.mv.err"; then
    assert_eq "$1 fixture rename succeeded: ${2##*/}" yes yes
  else
    assert_eq "$1 fixture rename succeeded: ${2##*/}" yes \
      "no(mv rc!=0; stderr: $(tr '\n' '|' <"$_ra_tmp_root/.ra.mv.err") — the fixture lacks the shape under test, so the arm below is vacuous)"
  fi
}

RA_WATCH_CHECKED=""      # rows _ra_watch_check was actually invoked for
RA_WATCH_ALL_MEMBERS=""  # every checked row's members, for the cross-row overlap test
_ra_watch_check() {  # row-name glob-dir literal-member...
  local _row="$1" _dir="$2" _helper _disk _globbed
  shift 2
  _helper="$(printf '%s\n' "$RA_LIST" | sed -n "s/^budget-watch	${_row}	//p" | sort)"
  # The glob is expanded HERE from a quoted directory rather than at the call site: an
  # unquoted `$( … ls dir/*.md )` argument splices its members as separate words but trips
  # SC2046, and CI's lint gate runs at --severity=warning.
  # Precondition the GLOB-derived portion on its own, NOT the assembled `_disk`. `_disk`
  # concatenates the literal members (emitted by the `printf` BUILTIN, so always present)
  # with the glob expansion, which makes it unconditionally non-empty — a guard over it
  # would be unreachable decoration whose failure text named causes (`ls` absent, the glob
  # matching nothing) it structurally could not observe. Guarding the glob half is what
  # actually detects those.
  _globbed="$( cd "$RA_REPO" && ls "$_dir"/*.md )"
  case "$_globbed" in
    '') assert_eq "#624 A4 the disk-derived glob members are non-empty: $_row" yes \
          "no(empty — ls absent, or $_dir/*.md matched nothing)" ;;
    *)  assert_eq "#624 A4 the disk-derived glob members are non-empty: $_row" yes yes ;;
  esac
  _disk="$( { printf '%s\n' "$@"; printf '%s\n' "$_globbed"; } | sort )"
  # `_helper` IS derived wholly through `sed`/`sort` — neither preflight-guaranteed — so a
  # missing tool empties it and the equality below would pass comparing "" to "" if `_disk`
  # were also empty (CLAUDE.md's un-guaranteed-tool rule: a value deciding an emitted result
  # must fail CLOSED). Guard it so tool absence surfaces as a named RED, not a vacuous pass.
  case "$_helper" in
    '') assert_eq "#624 A4 the helper-reported watch list is non-empty: $_row" yes \
          "no(empty — sed/sort absent, or --list emitted no budget-watch rows for $_row)" ;;
    *)  assert_eq "#624 A4 the helper-reported watch list is non-empty: $_row" yes yes ;;
  esac
  assert_eq "#624 A4 --list watch list equals the disk-derived bundle membership: $_row" \
    "$_disk" "$_helper"
  # Accumulate for the two registry-derived assertions below: which rows were checked, and
  # every checked row's members. Both reuse THIS extraction rather than re-deriving it, so
  # the non-empty guards above cover them and neither can pass vacuously. Accumulating
  # inside the function also removes the ordering-dependent out-parameter a per-call
  # capture would need — a reordered or inserted call site cannot bind the wrong row's list.
  RA_WATCH_CHECKED="$RA_WATCH_CHECKED$_row
"
  RA_WATCH_ALL_MEMBERS="$RA_WATCH_ALL_MEMBERS$_helper
"
}
_ra_watch_check review-bundle-budget "skills/review/phases" \
  "skills/review/SKILL.md" ".devflow/prompt-extensions/review.md"
_ra_watch_check review-and-fix-budget "skills/review-and-fix/references" \
  "skills/review-and-fix/SKILL.md" ".devflow/prompt-extensions/review-and-fix.md"

# ── Registry-derived coverage: every budget row --list emits is actually checked ──
# The call sites above are a hand-maintained enumeration of the budget-row population,
# while the REGISTRY is that population's single enumeration point (the property #619
# established and #624 preserved). Left uncoupled, a newly-registered budget row would get
# no watch-list equality assertion and no overlap comparison, and every arm above would
# stay green — the audit would certify its own completeness from its own enumeration, which
# is exactly the blind spot a detect-all audit cannot self-certify away. So derive the
# roster from --list's own row-name field and require it to equal the set actually checked:
# a registered row nobody checks, and a check naming a row --list does not emit, both go RED.
# Derived from BOTH attributed line kinds. A budget row emits a `budget-watch` line only
# for members that exist on disk, so a row whose literals and glob are ALL absent emits
# `budget-watch-missing` lines exclusively — extracting from `budget-watch` alone would
# leave that row out of the roster, and the equality below would pass while the row went
# unchecked. That is the same self-certifying blind spot this block exists to close, so it
# must not depend on an accident of the live tree having every member present.
#
# The derivation is a shared function precisely so the A4c arm below can drive it against a
# fixture that HAS the all-absent shape: on the live tree both spellings agree, so a
# single-prefix regression here would be invisible without that arm.
_ra_roster_of() {  # --list output -> sorted unique row names owning budget-watch* lines
  printf '%s\n' "$1" | sed -n 's/^budget-watch	\([^	]*\)	.*$/\1/p; s/^budget-watch-missing	\([^	]*\)	.*$/\1/p' | sort -u
}
RA_WATCH_EMITTED="$(_ra_roster_of "$RA_LIST")"
RA_WATCH_COVERED="$(printf '%s' "$RA_WATCH_CHECKED" | sort -u)"
# Both sides route through `sed`/`sort`, which lib/preflight.sh does not guarantee; a
# missing tool empties BOTH and the equality would pass comparing "" to "". Assert
# non-empty first so tool absence surfaces as a named RED, never a vacuous pass.
case "$RA_WATCH_EMITTED" in
  '') assert_eq "#624 A4 the --list-derived budget-row roster is non-empty" yes \
        "no(empty — sed/sort absent, or --list emitted no budget-watch rows at all)" ;;
  *)  assert_eq "#624 A4 the --list-derived budget-row roster is non-empty" yes yes ;;
esac
assert_eq "#624 A4 every budget row --list emits has a watch-list check (registry-derived)" \
  "$RA_WATCH_EMITTED" "$RA_WATCH_COVERED"

# ── Cross-row overlap: no member may belong to two budget rows ──
# Data-driven over EVERY checked row's members rather than a fixed pair, so it keeps
# holding as rows are added. Without it, a watch_globs typo aiming one row at another's
# bundle would leave each per-row equality green on its own terms while both rows silently
# watched the same files. Pure bash builtins (`read` + `case`) — never `comm`/`uniq`, whose
# absence would empty the result and pass VACUOUSLY, defeating the guards above (CLAUDE.md's
# un-guaranteed-tool rule: a value deciding an emitted result must fail closed). The newline
# sentinels make `case` match a WHOLE line, so one member cannot register as overlapping
# merely by being another's path prefix.
case "$RA_WATCH_ALL_MEMBERS" in
  '') assert_eq "#624 A4 the cross-row member set is non-empty (overlap test is live)" yes \
        "no(empty — no checked row contributed members, so the overlap test below would pass vacuously)" ;;
  *)  assert_eq "#624 A4 the cross-row member set is non-empty (overlap test is live)" yes yes ;;
esac
# Membership is a LITERAL substring test, never a `case` pattern: inside `case`, an
# expanded member is read as a glob, so a member containing `*`, `?` or `[` would match
# unrelated lines (a false overlap) or be absorbed and never recorded as seen. The registry
# genuinely carries such members — `skills/review/phases/*.md` appears verbatim on
# budget-watch-missing lines — so this is one row-schema change away from live. `${v#...}`
# with a quoted needle is builtin and literal, so it has neither hazard.
_ra_watch_overlaps() {  # newline-list-of-members -> overlapping members (empty when none)
  local _seen="" _dup="" _m
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    if [ "${_seen#*"
$_m
"}" != "$_seen" ]; then
      _dup="$_dup $_m"
    else
      _seen="$_seen
$_m
"
    fi
  done <<RA_WATCH_EOF
$1
RA_WATCH_EOF
  printf '%s' "$_dup"
}
assert_eq "#624 A4 no watch-list member belongs to more than one budget row" "" \
  "$(_ra_watch_overlaps "$RA_WATCH_ALL_MEMBERS")"
# Drive the detector's POSITIVE branch. Without this the arm above proves only that the
# loop terminates without appending: on the real tree the rows are disjoint by
# construction, so the reporting branch is never taken and an inverted test, a broken
# sentinel, or a mis-accumulated seen-set would leave it permanently green.
assert_eq "#624 A4 the overlap detector reports a member present in two rows" " dup/x.md" \
  "$(_ra_watch_overlaps 'a/one.md
dup/x.md
b/two.md
dup/x.md')"
# Anti-vacuity control: a member that is another's PREFIX must NOT register as an overlap,
# which is the property the newline sentinels buy.
assert_eq "#624 A4 the overlap detector does not treat a path prefix as an overlap" "" \
  "$(_ra_watch_overlaps 'a/one.md
a/one.md.bak')"

# ── A4c — a budget row whose members are ALL absent still enters the roster ──────
# The shape the roster derivation must not drop: such a row emits only
# `budget-watch-missing` lines, so a roster read from `budget-watch` alone omits it and the
# A4 equality above passes while the row goes unchecked — the self-certifying blind spot
# again, one level down. It is invisible on the live tree (every member exists there), so
# it is driven against a fixture with every review-and-fix member renamed away.
RA_A4C="$_ra_tmp_root/a4c"; _ra_fixture "$RA_A4C"
_ra_mv "#624 A4c" "$RA_A4C/skills/review-and-fix/references" "$RA_A4C/skills/review-and-fix/references-gone"
_ra_mv "#624 A4c" "$RA_A4C/skills/review-and-fix/SKILL.md" "$RA_A4C/skills/review-and-fix/SKILL-gone.md"
_ra_mv "#624 A4c" "$RA_A4C/.devflow/prompt-extensions/review-and-fix.md" "$RA_A4C/.devflow/prompt-extensions/review-and-fix-gone.md"
# Keep the helper's OWN exit status and stderr separate. Folding stderr into .ra.list and
# discarding rc would make a crash-before-emit_list indistinguishable from the shape under
# test: the counts below would read 0 and the negative precondition would PASS, leaving the
# roster `case` to fail with the wrong diagnosis (it would send a reader to audit
# `_ra_roster_of`'s sed when the real cause was a traceback sitting in .ra.list).
if python3 "$RA_HELPER" --list --repo-root "$RA_A4C" > "$RA_A4C/.ra.list" 2>"$RA_A4C/.ra.err"; then
  assert_eq "#624 A4c --list succeeds against the all-absent fixture" yes yes
else
  assert_eq "#624 A4c --list succeeds against the all-absent fixture" yes \
    "no(rc!=0; stderr: $(tr '\n' '|' <"$RA_A4C/.ra.err") — the assertions below would read 0 vacuously)"
fi
RA_A4C_LIST="$(cat "$RA_A4C/.ra.list")"
# NEGATIVE precondition: the renames took effect (no member is present for this row)…
assert_eq "#624 A4c the fixture really leaves the review-and-fix row with no present member" "0" \
  "$(devflow_module_pin_count 'budget-watch	review-and-fix-budget	' "$RA_A4C/.ra.list")"
# …and the POSITIVE one it stands in for: the row actually EMITS the shape this arm is
# about. Without it, "no budget-watch line" is satisfied just as well by a run that emitted
# nothing at all — a precondition standing in for an unverified consumption.
# The unestablished arm is separate from the zero arm, matching `_ra_has`'s house pattern:
# a bare `*)` catch-all would pass on ANY non-zero output including a non-numeric one, so a
# host where the counter emits a breadcrumb instead of a digit would fail OPEN here while
# `_ra_has` fails closed — the very guard class this arm is hardening.
case "$(devflow_module_pin_count 'budget-watch-missing	review-and-fix-budget	' "$RA_A4C/.ra.list")" in
  ''|*[!0-9]*) assert_eq "#624 A4c the fixture row emits budget-watch-missing lines" yes \
                 "no(count unestablished — the derivation itself failed)" ;;
  0)           assert_eq "#624 A4c the fixture row emits budget-watch-missing lines" yes \
                 "no(zero — the run or the renames failed; the roster check below would be vacuous)" ;;
  *)           assert_eq "#624 A4c the fixture row emits budget-watch-missing lines" yes yes ;;
esac
case "$(_ra_roster_of "$RA_A4C_LIST")" in
  *review-and-fix-budget*) assert_eq "#624 A4c an all-absent budget row still enters the roster" yes yes ;;
  *) assert_eq "#624 A4c an all-absent budget row still enters the roster" yes \
       "no(the roster derivation dropped a row that emits only budget-watch-missing lines)" ;;
esac

# ── A5 — exit 2 on an ABSENT generator, and exit 2 wins over a judgment item ─
# An absent script is reported by the INTERPRETER as exit 2 ("can't open file"), which
# the helper catches in its declared-set branch — NOT the OSError launch-failure branch
# (A5c below drives that one). The assertion pins a DISTINGUISHING substring plus the
# row-level attribution: a bare "INFRASTRUCTURE" match would be vacuous, because main()
# unconditionally prints a summary line carrying that word on every exit-2 path, so it
# would still pass with row-level attribution deleted.
RA_A5="$_ra_tmp_root/a5"; mkdir -p "$RA_A5"
_ra_run "$RA_A5"
assert_eq "#619 A5 an absent generator under --repo-root exits 2" "2" "$(_ra_rc "$RA_A5")"
_ra_has "#619 A5 the absent generator is attributed to its ROW, not just the summary" \
  "$RA_A5" "[cloud-writer-manifest] INFRASTRUCTURE"
_ra_has "#619 A5 the absent generator names the declared-set branch" "$RA_A5" "outside its declared set"
_ra_has "#619 A5 the absent generator names the missing target" "$RA_A5" "(target absent: lib/test/cloud_writer_contract.py)"
_ra_live_unchanged "#619 A5 live manifest byte-unchanged after the absent-generator run"

RA_A5P="$_ra_tmp_root/a5p"; _ra_fixture "$RA_A5P"
# A judgment item AND an infrastructure failure in one run: exit 2 takes precedence.
printf '\n<!-- #619 census drift -->\n' >> "$RA_A5P/.devflow/prompt-extensions/implement.md"
rm -f "$RA_A5P/lib/generate-capability-profiles.py"
_ra_run "$RA_A5P"
# Positive control for the precedence claim (guard-class shape 3). The rc assertion
# below passes on the infrastructure condition ALONE — `main()` returns 2 whenever
# `infrastructure` is set, regardless of `forces_one` — so without establishing that a
# judgment item was ALSO present, the arm measures a plain exit-2 run and would stay
# green if the census silently stopped reporting drift for this edit shape. Pin the
# judgment row's own attributed signal first, so precedence is what is actually tested.
_ra_has "#619 A5p the concurrent judgment item is present (precedence positive control)" \
  "$RA_A5P" "[prompt-mass-baseline] JUDGMENT"
assert_eq "#619 A5 exit 2 takes precedence over a concurrent judgment item" "2" "$(_ra_rc "$RA_A5P")"
_ra_live_unchanged "#619 A5p live manifest byte-unchanged after the precedence run"

# ── A5q — the MECHANICAL row regenerates while ANOTHER row hits infrastructure ──
# The regeneration is exit-1-forcing and the infrastructure state wins, so the caller
# gets exit 2 over a manifest that WAS rewritten and still must be committed. Nothing
# else exercises that combination: every other exit-2 arm leaves the mechanical row
# clean or makes it the infrastructure source itself. A regression that skipped the
# remaining rows on the first infrastructure hit — or dropped the earlier rows' report
# lines — would ship green without this.
RA_A5Q="$_ra_tmp_root/a5q"; _ra_fixture "$RA_A5Q"
printf '{"corrupted": true}\n' > "$RA_A5Q/scripts/devflow-cloud-writer-contract.json"
RA_A5Q_BEFORE="$(cat "$RA_A5Q/scripts/devflow-cloud-writer-contract.json")"
rm -f "$RA_A5Q/lib/generate-capability-profiles.py"
_ra_run "$RA_A5Q"
assert_eq "#619 A5q a regenerating mechanical row plus an infrastructure row exits 2" \
  "2" "$(_ra_rc "$RA_A5Q")"
# The positive control: exit 2 alone would pass on the infrastructure condition, so pin
# that the regeneration genuinely happened and was still reported in the same run.
_ra_has "#619 A5q the regenerated manifest is still reported alongside the exit-2 state" \
  "$RA_A5Q" "REGENERATED scripts/devflow-cloud-writer-contract.json"
_ra_has "#619 A5q the infrastructure half is attributed to its own row" "$RA_A5Q" \
  "[capability-profile-literals] INFRASTRUCTURE"
_ra_same "#619 A5q the manifest was rewritten despite the exit-2 outcome" changed \
  "$([ "$RA_A5Q_BEFORE" != "$(cat "$RA_A5Q/scripts/devflow-cloud-writer-contract.json")" ] \
    && echo changed || echo unchanged)" \
  "the exit-2 run skipped the mechanical regeneration"
_ra_live_unchanged "#619 A5q live manifest byte-unchanged after the regenerate-plus-infra run"

# ── A5r — an UNREADABLE artifact snapshot routes to exit 2, never exit 1 ────
# Scope, stated exactly: this arm covers run_row's SNAPSHOT-READ guard — the try/except
# OSError bracketing the mechanical row's before/after read_bytes, which sits outside
# that row's subprocess try. It does NOT reach the helper's top-level exception net:
# this OSError is handled at the row level and main() returns normally. The net is
# unexercised-by-design defence-in-depth — no CLI-reachable input shape raises past the
# row handlers — and no arm here claims otherwise.
# An unreadable manifest is the shape a half-restored worktree actually produces. Note
# chmod 000 ALSO breaks the generator's own write, which independently yields exit 2 on
# the same row, so the exit code and the row-attributed INFRASTRUCTURE line are NOT
# sufficient evidence — the snapshot branch's own literal is pinned below to attribute
# it.
RA_A5R="$_ra_tmp_root/a5r"; _ra_fixture "$RA_A5R"
chmod 000 "$RA_A5R/scripts/devflow-cloud-writer-contract.json" 2>/dev/null
if [ -r "$RA_A5R/scripts/devflow-cloud-writer-contract.json" ]; then
  # Running as root (or on a filesystem ignoring mode bits) makes the unreadable state
  # unreachable, so the arm cannot be expressed here. Say so rather than asserting a
  # pass the host never established.
  assert_eq "#619 A5r an unreadable artifact snapshot routes to exit 2" yes \
    "no(host could not make the file unreadable — chmod 000 still readable)"
else
  _ra_run "$RA_A5R"
  assert_eq "#619 A5r an unreadable artifact snapshot routes to exit 2, never exit 1" \
    "2" "$(_ra_rc "$RA_A5R")"
  _ra_has "#619 A5r the unreadable snapshot is attributed to its row as INFRASTRUCTURE" \
    "$RA_A5R" "[cloud-writer-manifest] INFRASTRUCTURE"
  # The distinguishing evidence: this literal is emitted ONLY by the snapshot-read
  # guard. Without it the arm passes on the generator's own write failure, so deleting
  # the guard under test would leave it green.
  _ra_has "#619 A5r the snapshot-read guard is the branch that fired" "$RA_A5R" \
    "could not read scripts/devflow-cloud-writer-contract.json before the run"
  # The report must survive: a state that printed nothing is what makes the consumers'
  # guard read "nothing to do".
  _ra_has "#619 A5r later rows still report despite the earlier row's failure" \
    "$RA_A5R" "[coverage-map-ratchet]"
fi
chmod 644 "$RA_A5R/scripts/devflow-cloud-writer-contract.json" 2>/dev/null
_ra_live_unchanged "#619 A5r live manifest byte-unchanged after the unreadable-snapshot run"

# ── A5s — an argparse USAGE error exits 2 and runs no row ────────────────────
# The helper's exit-contract docstring makes a positive claim about this boundary
# (rc 2, before any row runs, with no row report). An untested documented claim in a
# file this module content-pins elsewhere is a documented-falsehood risk.
RA_A5S="$_ra_tmp_root/a5s"; _ra_fixture "$RA_A5S"
# Drift is PLANTED first, deliberately: on a reconciled fixture the mechanical row would
# rewrite byte-identical content, so `unchanged` would hold even if argparse failed to
# short-circuit and the row DID run — proving nothing. Against a corrupted manifest,
# `unchanged` means the row genuinely never executed.
printf '{"corrupted": true}\n' > "$RA_A5S/scripts/devflow-cloud-writer-contract.json"
RA_A5S_BEFORE="$(cat "$RA_A5S/scripts/devflow-cloud-writer-contract.json")"
python3 "$RA_HELPER" --repo-root "$RA_A5S" --no-such-flag \
  >"$RA_A5S/.ra.out" 2>&1; printf '%s\n' "$?" >"$RA_A5S/.ra.rc"
assert_eq "#619 A5s an unknown flag exits 2" "2" "$(_ra_rc "$RA_A5S")"
case "$(cat "$RA_A5S/.ra.out")" in
  *"[cloud-writer-manifest]"*|*"regenerate-artifacts: "*)
    assert_eq "#619 A5s the usage error emits no row report" yes \
      "no(a row report accompanied the usage error)" ;;
  *) assert_eq "#619 A5s the usage error emits no row report" yes yes ;;
esac
_ra_same "#619 A5s the usage error ran no row (fixture manifest untouched)" unchanged \
  "$([ "$RA_A5S_BEFORE" = "$(cat "$RA_A5S/scripts/devflow-cloud-writer-contract.json")" ] \
    && echo unchanged || echo changed)" \
  "a row ran despite the usage error"
_ra_live_unchanged "#619 A5s live manifest byte-unchanged after the usage-error run"

# ── A5b — a launched command exiting OUTSIDE its declared set is exit 2 ──────
RA_A5B="$_ra_tmp_root/a5b"; _ra_fixture "$RA_A5B"
printf 'import sys\nsys.exit(3)\n' > "$RA_A5B/lib/test/coverage_map_guard.py"
_ra_run "$RA_A5B"
assert_eq "#619 A5b an out-of-declared-set exit routes to exit 2, never clean" "2" "$(_ra_rc "$RA_A5B")"
_ra_has "#619 A5b the out-of-set exit names the declared set" "$RA_A5B" "outside its declared set"
_ra_live_unchanged "#619 A5b live manifest byte-unchanged after the out-of-set run"

# ── A5c — the OSError LAUNCH-FAILURE branch (distinct from A5's declared-set arm) ─
# A5 exercises an absent *script* (the interpreter exits 2, caught by the declared-set
# check). Nothing reached the helper's `except OSError` arm, so a regression that
# swallowed a launch failure — or returned "clean" from it — would have shipped green.
# A nonexistent --repo-root makes subprocess.run itself raise (the cwd does not exist),
# which is the only shape that reaches that branch.
RA_A5C="$_ra_tmp_root/a5c-does-not-exist"
python3 "$RA_HELPER" --repo-root "$RA_A5C" >"$_ra_tmp_root/a5c.out" 2>&1; printf '%s\n' "$?" >"$_ra_tmp_root/a5c.rc"
assert_eq "#619 A5c an unlaunchable command (nonexistent root) exits 2" "2" "$(cat "$_ra_tmp_root/a5c.rc")"
# Presence, not an exact count: every command row fails to launch under a nonexistent
# root, so the line legitimately appears once per command row — pinning the current
# number would be a mirror-fact that rots the moment a row is added.
devflow_module_pin_present "#619 A5c the launch failure is named as such" \
  'INFRASTRUCTURE the command failed to launch' "$_ra_tmp_root/a5c.out"
_ra_live_unchanged "#619 A5c live manifest byte-unchanged after the launch-failure run"

# ── A5d — the coverage-map row's JUDGMENT arm (its drift path was unexercised) ───
# Every other judgment row had its JUDGMENT line and policy string pinned; this one was
# reachable only via A1 (clean) and A5b (out-of-set), so a typo in its exits/clean tuple
# would have turned every real ratchet failure into a spurious exit 2 unnoticed.
RA_A5D="$_ra_tmp_root/a5d"; _ra_fixture "$RA_A5D"
printf '# scratch\n' > "$RA_A5D/lib/uncovered-helper-619.sh"
( cd "$RA_A5D" && git add -A && git commit -q -m "plant coverage drift" ) >/dev/null 2>&1
_ra_reconcile "$RA_A5D"
_ra_run "$RA_A5D"
_ra_has "#619 A5d planted coverage-map drift raises the ratchet judgment item" "$RA_A5D" \
  "[coverage-map-ratchet] JUDGMENT"
_ra_has "#619 A5d the ratchet item names its governing policy" "$RA_A5D" \
  "add the missing coverage rows per the issue-591 ratchet"
assert_eq "#619 A5d the ratchet judgment item forces exit 1" "1" "$(_ra_rc "$RA_A5D")"
_ra_live_unchanged "#619 A5d live manifest byte-unchanged after the ratchet-drift run"

# ── A5e — a RENAMED watch-list member reports unestablished, never a false clean ──
# The fail-open this closes: an is_file() filter silently dropped a moved member, so the
# budget row answered "no review-bundle member changed" for the very change that moved
# it. The arm renames a literal member and asserts the row refuses to answer.
RA_A5E="$_ra_tmp_root/a5e"; _ra_fixture "$RA_A5E"
_ra_mv "#619 A5e" "$RA_A5E/.devflow/prompt-extensions/review.md" "$RA_A5E/.devflow/prompt-extensions/review-renamed.md"
_ra_run "$RA_A5E"
_ra_has "#619 A5e a renamed watch-list member reports unestablished" "$RA_A5E" \
  "watch-list member(s) absent from the tree"
# Pin the ROW-ATTRIBUTED composite, never the bare path: renaming that file also breaks
# the prompt-mass census, whose JUDGMENT output names the same path, so a bare-path pin
# would still pass with the budget row's own interpolation deleted (the same vacuity
# A5 above was fixed for).
_ra_has "#619 A5e the unestablished watch-list line names the missing member" "$RA_A5E" \
  "absent from the tree: .devflow/prompt-extensions/review.md"
# PTA: --list's budget-watch-missing loop is otherwise unexecuted by the suite (A4 runs
# against a tree where `missing` is always empty), so the list surface could silently
# stop disclosing a renamed member.
if python3 "$RA_HELPER" --list --repo-root "$RA_A5E" > "$RA_A5E/.ra.list" 2>"$RA_A5E/.ra.err"; then
  assert_eq "#619 A5e --list succeeds against the renamed-member fixture" yes yes
else
  assert_eq "#619 A5e --list succeeds against the renamed-member fixture" yes \
    "no(rc!=0; stderr: $(tr '\n' '|' <"$RA_A5E/.ra.err"))"
fi
assert_eq "#619 A5e --list discloses the missing member" "1" \
  "$(devflow_module_pin_count 'budget-watch-missing	review-bundle-budget	.devflow/prompt-extensions/review.md' "$RA_A5E/.ra.list")"
_ra_live_unchanged "#619 A5e live manifest byte-unchanged after the renamed-member run"

# ── A5g — a judgment row's INPUT failure routes to INFRASTRUCTURE, not to a judgment ──
# Both judgment generators exit 1 for an unusable input as well as for real drift, so
# without a discriminator an unmeasurable tree is reported as "go edit your coverage
# rows" — telling the agent to fix a measurement that never happened. Stripping .git
# from the fixture makes coverage_map_guard emit its `[input-error]` prefix; the row
# must report INFRASTRUCTURE (exit 2), never a JUDGMENT item (exit 1).
RA_A5G="$_ra_tmp_root/a5g"; _ra_fixture "$RA_A5G"; rm -rf "$RA_A5G/.git"
_ra_run "$RA_A5G"
assert_eq "#619 A5g a judgment row's input failure exits 2, never 1" "2" "$(_ra_rc "$RA_A5G")"
_ra_has "#619 A5g the input failure is attributed to its row as INFRASTRUCTURE" "$RA_A5G" \
  "[coverage-map-ratchet] INFRASTRUCTURE"
_ra_has "#619 A5g the input failure is named as an input failure, not drift" "$RA_A5G" \
  "reporting an input failure, not drift"
_ra_has "#619 A5g the run does NOT tell the agent to resolve a ratchet judgment item" "$RA_A5G" \
  "the artifact was NOT checked"
_ra_live_unchanged "#619 A5g live manifest byte-unchanged after the input-failure run"

# ── A5h — a mechanical generator that exits 0 WITHOUT writing is infrastructure ──
# `before` and `after` are both None when the artifact is absent on both sides, so
# `before != after` is False and the row would have reported "already matches the
# closure" — an absent artifact asserted to match. Two failed measurements read as
# equality. Nothing pinned this branch: every other mechanical arm has a generator that
# actually writes.
RA_A5H="$_ra_tmp_root/a5h"; _ra_fixture "$RA_A5H"
printf 'import sys\nsys.exit(0)\n' > "$RA_A5H/lib/test/cloud_writer_contract.py"
rm -f "$RA_A5H/scripts/devflow-cloud-writer-contract.json"
_ra_run "$RA_A5H"
assert_eq "#619 A5h a clean exit that produced no artifact exits 2" "2" "$(_ra_rc "$RA_A5H")"
_ra_has "#619 A5h the absent artifact is named, not reported as a match" "$RA_A5H" \
  "the generator produced no artifact"
_ra_live_unchanged "#619 A5h live manifest byte-unchanged after the no-artifact run"

# ── A5i — a RENAMED glob parent reports unestablished (the glob leg of watch_list) ──
# A5e covers the literal leg. Path.glob over a nonexistent directory yields nothing and
# raises nothing, so a renamed skills/review/phases/ would empty the member list in
# silence and the budget row would answer "no review-bundle member changed" for exactly
# the change that moved them. Deleting the is_dir() guard leaves every other arm green.
RA_A5I="$_ra_tmp_root/a5i"; _ra_fixture "$RA_A5I"
_ra_mv "#619 A5i" "$RA_A5I/skills/review/phases" "$RA_A5I/skills/review/phases-renamed"
if python3 "$RA_HELPER" --list --repo-root "$RA_A5I" > "$RA_A5I/.ra.list" 2>"$RA_A5I/.ra.err"; then
  assert_eq "#619 A5i --list succeeds against the renamed-parent fixture" yes yes
else
  assert_eq "#619 A5i --list succeeds against the renamed-parent fixture" yes \
    "no(rc!=0; stderr: $(tr '\n' '|' <"$RA_A5I/.ra.err"))"
fi
assert_eq "#619 A5i --list discloses the renamed glob parent as missing" "1" \
  "$(devflow_module_pin_count 'budget-watch-missing	review-bundle-budget	skills/review/phases/*.md' "$RA_A5I/.ra.list")"
_ra_run "$RA_A5I"
_ra_has "#619 A5i a renamed glob parent reports unestablished, never a false clean" "$RA_A5I" \
  "absent from the tree: skills/review/phases/*.md"
_ra_live_unchanged "#619 A5i live manifest byte-unchanged after the renamed-parent run"

# ── A5i2 — a DELETED individual glob member still trips the budget row ───────
# A5e closes the renamed-literal leg and A5i the renamed-PARENT leg; an individual
# phases/*.md deleted or renamed is the third and was open: the parent still exists (so
# `missing` stays empty and the unestablished arm never fires) and the old path is gone
# from disk (so it is absent from the expanded member list), while git still reports it
# in the change set. Intersecting on the expanded members alone would answer "no
# review-bundle member changed" for exactly the change that moved it. The fnmatch leg is
# what catches it — deleting it turns this arm RED and nothing else.
RA_A5I2="$_ra_tmp_root/a5i2"; _ra_fixture "$RA_A5I2"
rm -f "$RA_A5I2/skills/review/phases/phase-4-1-8-prose-cutover.md"
# No _ra_reconcile here, deliberately: deleting a reached phase file breaks the
# cloud-writer CLOSURE, which `generate` cannot repair (it exits 1), so a reconcile
# would fail rather than quiet the other rows. The assertions below pin the budget
# row's OWN attributed line instead, so a concurrently-drifted row cannot stand in for
# it — the same row-attribution discipline A5/A5e use in place of a bare match.
_ra_run "$RA_A5I2"
_ra_has "#619 A5i2 a deleted glob member trips the budget judgment item" "$RA_A5I2" \
  "[review-bundle-budget] JUDGMENT"
# The COMPOSITE, not the bare path: this arm deliberately skips _ra_reconcile, so the
# cloud-writer closure is broken and its row prints the same path verbatim — a bare-path
# pin would pass with the fnmatch leg deleted. `changed members:` is the budget row's own.
_ra_has "#619 A5i2 the deleted member is named as the changed member" "$RA_A5I2" \
  "changed members: skills/review/phases/phase-4-1-8-prose-cutover.md"
_ra_live_unchanged "#619 A5i2 live manifest byte-unchanged after the deleted-member run"

# ── A5i3 — the NEW row's renamed glob parent reports unestablished + attributed ──
# A5i covers the review-bundle row's glob leg. The review-and-fix row's `missing` leg was
# reached by no arm: emit_list builds its budget-watch-missing line from the same
# row['name'] in the same loop, so it is very likely correct — but "very likely correct"
# is what an unpinned leg always looks like, and a renamed references/ directory would
# leave this row silently reporting unestablished with nobody watching.
RA_A5I3="$_ra_tmp_root/a5i3"; _ra_fixture "$RA_A5I3"
_ra_mv "#624 A5i3" "$RA_A5I3/skills/review-and-fix/references" "$RA_A5I3/skills/review-and-fix/references-renamed"
if python3 "$RA_HELPER" --list --repo-root "$RA_A5I3" > "$RA_A5I3/.ra.list" 2>"$RA_A5I3/.ra.err"; then
  assert_eq "#624 A5i3 --list succeeds against the renamed-references fixture" yes yes
else
  assert_eq "#624 A5i3 --list succeeds against the renamed-references fixture" yes \
    "no(rc!=0; stderr: $(tr '\n' '|' <"$RA_A5I3/.ra.err"))"
fi
assert_eq "#624 A5i3 --list discloses the renamed references parent under its OWN row" "1" \
  "$(devflow_module_pin_count 'budget-watch-missing	review-and-fix-budget	skills/review-and-fix/references/*.md' "$RA_A5I3/.ra.list")"
_ra_run "$RA_A5I3"
_ra_has "#624 A5i3 the renamed references parent reports unestablished, never a false clean" "$RA_A5I3" \
  "absent from the tree: skills/review-and-fix/references/*.md"
_ra_has "#624 A5i3 the unestablished line is attributed to the review-and-fix row" "$RA_A5I3" \
  "[review-and-fix-budget] INFO unestablished"
_ra_live_unchanged "#624 A5i3 live manifest byte-unchanged after the renamed-references run"

# ── A5i4 — the NEW row's renamed LITERAL member reports unestablished + attributed ──
# A5i3 covers this row's glob leg; A5e covers the sibling row's literal leg. The new row's
# own literal leg was the one place a watch_literals copy-paste from the sibling row would
# go undetected — the same residual-symmetry argument A5i3 makes, one step further.
RA_A5I4="$_ra_tmp_root/a5i4"; _ra_fixture "$RA_A5I4"
_ra_mv "#624 A5i4" "$RA_A5I4/.devflow/prompt-extensions/review-and-fix.md" "$RA_A5I4/.devflow/prompt-extensions/review-and-fix-renamed.md"
# Own exit status + separate stderr, same reason as A4c: a crash also yields count 0, and
# this arm's expected 1 would then go RED with the misleading message "row attribution
# regressed" while the explaining traceback sat unread inside .ra.list.
if python3 "$RA_HELPER" --list --repo-root "$RA_A5I4" > "$RA_A5I4/.ra.list" 2>"$RA_A5I4/.ra.err"; then
  assert_eq "#624 A5i4 --list succeeds against the renamed-literal fixture" yes yes
else
  assert_eq "#624 A5i4 --list succeeds against the renamed-literal fixture" yes \
    "no(rc!=0; stderr: $(tr '\n' '|' <"$RA_A5I4/.ra.err"))"
fi
assert_eq "#624 A5i4 --list discloses the renamed literal member under its OWN row" "1" \
  "$(devflow_module_pin_count 'budget-watch-missing	review-and-fix-budget	.devflow/prompt-extensions/review-and-fix.md' "$RA_A5I4/.ra.list")"
_ra_run "$RA_A5I4"
_ra_has "#624 A5i4 the renamed literal member reports unestablished, never a false clean" "$RA_A5I4" \
  "absent from the tree: .devflow/prompt-extensions/review-and-fix.md"
_ra_has "#624 A5i4 the unestablished line is attributed to the review-and-fix row" "$RA_A5I4" \
  "[review-and-fix-budget] INFO unestablished"
_ra_live_unchanged "#624 A5i4 live manifest byte-unchanged after the renamed-literal run"

# ── A5j — an UNREADABLE coverage-map is infrastructure, not "add the missing rows" ──
# A5g covers the guard's [input-error] (git) path. An absent/malformed coverage-map
# takes a DIFFERENT path ([arm4]/[arm8]) and arm 4 RETURNS before every map-dependent
# arm — so an unreadable map both suppresses every real violation and, unmarked, would
# be reported as a judgment item telling the agent to add rows to the very file the
# guard just said it could not read.
RA_A5J="$_ra_tmp_root/a5j"; _ra_fixture "$RA_A5J"
rm -f "$RA_A5J/lib/test/modules/coverage-map.json"
_ra_run "$RA_A5J"
assert_eq "#619 A5j an unreadable coverage-map exits 2, never 1" "2" "$(_ra_rc "$RA_A5J")"
_ra_has "#619 A5j the unreadable map is matched by its own arm4 marker" "$RA_A5J" \
  "matched '[arm4] '"
_ra_live_unchanged "#619 A5j live manifest byte-unchanged after the unreadable-map run"

# ── A5k — a MALFORMED capability manifest is infrastructure, not "regenerate" ──
# The generator raises GenError and exits 1 for an unreadable/malformed manifest —
# byte-identically to a real token drift. Unmarked, the row would report a judgment
# item telling the agent to regenerate from the very file the generator could not
# parse, and the pass would record `run` for a row that was never checked. This row
# was the only judgment row shipping without infra_markers.
RA_A5K="$_ra_tmp_root/a5k"; _ra_fixture "$RA_A5K"
printf '{ not json at all\n' > "$RA_A5K/lib/capability-profiles.json"
_ra_run "$RA_A5K"
assert_eq "#619 A5k a malformed capability manifest exits 2, never 1" "2" "$(_ra_rc "$RA_A5K")"
_ra_has "#619 A5k the malformed manifest is attributed to its own row" "$RA_A5K" \
  "[capability-profile-literals] INFRASTRUCTURE"
# The RENDERED discriminator, not the bare payload: `manifest malformed JSON:` also
# appears in the row's echoed command output, so pinning it would pass even if
# _marker_hit returned None and the row was classified JUDGMENT. The `matched '...'`
# wording is emitted ONLY by run_row's marker-hit branch.
_ra_has "#619 A5k the malformed manifest is matched by its own marker" "$RA_A5K" \
  "matched 'manifest malformed JSON:'"
_ra_live_unchanged "#619 A5k live manifest byte-unchanged after the malformed-manifest run"

# ── A5m — the CENSUS infra_markers are exercised (they were declared but dead) ──
# Every other INFRASTRUCTURE assertion targets the cloud-writer or coverage-map rows,
# so a typo in the census row's three marker literals shipped green: the row would
# report an unmeasurable tree as a judgment item telling the agent to edit a baseline
# whose measurement never happened. An absent CLAUDE.md is a census input failure
# (`: unreadable:` / `not found or not a directory` class), not baseline drift.
# A MALFORMED census manifest is the `: malformed JSON:` shape — a deterministic input
# failure that needs no permission bits (the census derives sizes with os.path.getsize,
# so an unreadable listed file does NOT fail it; only its own JSON reads do). A merely
# ABSENT listed file is a manifest COMPLETENESS failure, which is genuine drift and
# deliberately does not match the markers — matching it would hide a real finding.
RA_A5M="$_ra_tmp_root/a5m"; _ra_fixture "$RA_A5M"
printf '{ not json at all\n' > "$RA_A5M/lib/test/prompt-mass-manifest.json"
_ra_run "$RA_A5M"
assert_eq "#619 A5m a census input failure exits 2, never 1" "2" "$(_ra_rc "$RA_A5M")"
_ra_has "#619 A5m the census input failure is attributed to its own row" "$RA_A5M" \
  "[prompt-mass-baseline] INFRASTRUCTURE"
# Rendered discriminator, same reason as A5k above.
_ra_has "#619 A5m the census input failure is matched by its own marker" "$RA_A5M" \
  "matched ': malformed JSON:'"
_ra_live_unchanged "#619 A5m live manifest byte-unchanged after the census-input-failure run"

# ── A5n — _marker_hit scopes per LINE: a marker split across two lines is NOT a hit ──
# The docstring claims a marker can never be assembled across a line break from two
# unrelated messages. Replacing the per-line scan with `m in output` leaves every other
# assertion in this module green, so without this arm that claim is unpinned. The stub
# prints a marker split exactly at a newline: matched against the concatenated blob it
# would read as `: malformed JSON:` and be misreported as INFRASTRUCTURE; scoped per
# line it is neither, so the row must fall through to JUDGMENT.
RA_A5N="$_ra_tmp_root/a5n"; _ra_fixture "$RA_A5N"
printf 'import sys
sys.stdout.write("prompt-mass census: /x/y: malformed\nJSON: nope\n")
sys.exit(1)
'   > "$RA_A5N/lib/test/prompt-mass-census.py"
_ra_run "$RA_A5N"
_ra_has "#619 A5n a marker split across two lines is not a marker hit" "$RA_A5N" \
  "[prompt-mass-baseline] JUDGMENT"
assert_eq "#619 A5n the split-marker run forces exit 1, not the exit-2 infra state" "1" \
  "$(_ra_rc "$RA_A5N")"
_ra_live_unchanged "#619 A5n live manifest byte-unchanged after the split-marker run"

# ── A5f — default_repo_root anchors its probe to THIS checkout, not the process cwd ──
# The helper's one write target is a tracked file, so a root resolved from an unrelated
# repository would regenerate that repository's manifest. Nothing exercised the anchor:
# every other arm passes --repo-root explicitly, so deleting `cwd=str(here)` left all
# assertions green. Run --list with NO --repo-root from inside an unrelated git repo and
# assert the watch list is still DevFlow's own bundle.
RA_A5F="$_ra_tmp_root/a5f-unrelated"; mkdir -p "$RA_A5F"
( cd "$RA_A5F" && git init -q . && git config user.email a@b.c && git config user.name t \
  && printf 'x\n' > f.txt && git add -A && git commit -q -m unrelated ) >/dev/null 2>&1
if ( cd "$RA_A5F" && python3 "$RA_HELPER" --list ) > "$RA_A5F/list.out" 2>"$RA_A5F/list.err"; then
  assert_eq "#619 A5f --list succeeds from the unrelated repo" yes yes
else
  assert_eq "#619 A5f --list succeeds from the unrelated repo" yes \
    "no(rc!=0; stderr: $(tr '\n' '|' <"$RA_A5F/list.err"))"
fi
assert_eq "#619 A5f --list from an unrelated repo still resolves THIS checkout's bundle" "1" \
  "$(devflow_module_pin_count 'budget-watch	review-bundle-budget	skills/review/SKILL.md' "$RA_A5F/list.out")"
# #624: the sibling budget row is anchored by the SAME default_repo_root probe, so it gets
# its own positive assertion — otherwise deleting `cwd=str(here)` could be caught for one
# row while the other's anchoring stayed unpinned.
assert_eq "#624 A5f --list from an unrelated repo also resolves the review-and-fix bundle" "1" \
  "$(devflow_module_pin_count 'budget-watch	review-and-fix-budget	skills/review-and-fix/SKILL.md' "$RA_A5F/list.out")"
# Deliberately the bare tab-prefixed path, NOT the row-attributed form: with two attributed
# line kinds this catches an unrelated-repo member leaking onto EITHER a budget-watch or a
# budget-watch-missing line, under EITHER row. Restoring the attributed prefix would narrow
# it back to one row's one line kind and silently lose the other three.
assert_eq "#619 A5f the unrelated repo contributes no watch-list member" "0" \
  "$(devflow_module_pin_count '	f.txt' "$RA_A5F/list.out")"
_ra_live_unchanged "#619 A5f live manifest byte-unchanged after the unrelated-repo run"

# ── A6 — an underivable change set is `unestablished`, never exit-1-forcing ──
RA_A6="$_ra_tmp_root/a6"; _ra_fixture "$RA_A6"
# Remove the synthetic origin/main so the merge-base leg cannot resolve, and change a
# watch-list member: the budget row must degrade to an informational line rather than
# forcing an exit state it cannot substantiate, and the run stays 0 because no other
# row drifted.
# An EXISTING member is edited, then the other rows are reconciled. A brand-new phase
# file cannot be used here: it is an unclassified asset, which both the cloud-writer
# closure and the census sweep pattern reject by design, and neither rejection is
# reconcilable by regeneration alone. Editing an existing member drifts only the
# manifest hash and the census byte count, both of which _ra_reconcile regenerates —
# leaving the budget row as the only row with anything to say.
printf '\n<!-- #619 bundle drift -->\n' >> "$RA_A6/skills/review/phases/phase-0-setup.md"
_ra_reconcile "$RA_A6"
git -C "$RA_A6" update-ref -d refs/remotes/origin/main >/dev/null 2>&1
_ra_run "$RA_A6"
_ra_has "#619 A6 an underivable change set reports unestablished" "$RA_A6" "INFO unestablished"
assert_eq "#619 A6 the unestablished arm forces no exit state (run stays 0)" "0" "$(_ra_rc "$RA_A6")"
_ra_live_unchanged "#619 A6 live manifest byte-unchanged after the unestablished run"

# ── A6b — an UNTRACKED watch-list member still trips the budget row ──────────
# The precedented edit shape a tracked-only diff misses: a brand-new phase reference
# that has not been `git add`ed yet.
RA_A6B="$_ra_tmp_root/a6b"; _ra_fixture "$RA_A6B"
# No _ra_reconcile here: a brand-new phase file is an unclassified asset that the
# closure and the census both reject by design, so it cannot be reconciled away. The
# ATTRIBUTABLE assertion for this arm is therefore the budget JUDGMENT line itself —
# the exit-code assertion below corroborates it but does not attribute it (A3 is what
# pins "a judgment item forces the action-required state" on its own).
printf '# scratch\n' > "$RA_A6B/skills/review/phases/phase-9-fixture.md"
_ra_run "$RA_A6B"
_ra_has "#619 A6b an untracked bundle member trips the budget judgment item" "$RA_A6B" \
  "[review-bundle-budget] JUDGMENT"
_ra_has "#619 A6b the budget item names the record and the measurement rule" "$RA_A6B" \
  "_rb_words"
assert_eq "#619 A6b the untracked-member budget item forces exit 1" "1" "$(_ra_rc "$RA_A6B")"
_ra_live_unchanged "#619 A6b live manifest byte-unchanged after the untracked-member run"

# ── A6c — a touched record resolves the budget item (a reachable resolved state) ─
RA_A6C="$_ra_tmp_root/a6c"; _ra_fixture "$RA_A6C"
# Same isolation approach as A6: edit an existing member, then reconcile the other
# rows so the budget row is the only one left with anything to report.
printf '\n<!-- #619 bundle drift -->\n' >> "$RA_A6C/skills/review/phases/phase-0-setup.md"
_ra_reconcile "$RA_A6C"
printf '\n<!-- #619 record updated -->\n' >> "$RA_A6C/docs/review-bundle-budget.md"
_ra_run "$RA_A6C"
_ra_has "#619 A6c a branch that updated the record gets an informational line" "$RA_A6C" \
  "[review-bundle-budget] INFO bundle members changed"
assert_eq "#619 A6c a branch that updated the record runs clean" "0" "$(_ra_rc "$RA_A6C")"
_ra_live_unchanged "#619 A6c live manifest byte-unchanged after the resolved-record run"

# ── A6d — the review-and-fix budget row's JUDGMENT arm (issue #624) ──────────
# The sibling git-staleness row's exit-1-forcing arm, mirroring A6b/A6c for the review
# bundle. PR #622 hit this drift against the live suite; before this row the
# loop discovered it only a full suite run later. Same isolation approach as A6c: edit an
# EXISTING member (a brand-new reference is an unclassified asset that neither the
# cloud-writer closure nor the census sweep can reconcile), then reconcile the other rows
# so this row is the only one with anything to report.
RA_A6D="$_ra_tmp_root/a6d"; _ra_fixture "$RA_A6D"
printf '\n<!-- #624 raf bundle drift -->\n' >> "$RA_A6D/skills/review-and-fix/references/fixing.md"
_ra_reconcile "$RA_A6D"
_ra_run "$RA_A6D"
_ra_has "#624 A6d a changed review-and-fix member trips its own budget judgment item" "$RA_A6D" \
  "[review-and-fix-budget] JUDGMENT"
# The row-attributed COMPOSITE, never the bare path: the sibling review-bundle row prints
# the identical `changed members:` wording, so a bare-path pin would still pass with this
# row's watch list pointed at the wrong bundle.
_ra_has "#624 A6d the changed review-and-fix member is named by this row" "$RA_A6D" \
  "changed members: skills/review-and-fix/references/fixing.md"
_ra_has "#624 A6d the item names its own record, not the review-bundle record" "$RA_A6D" \
  "apply one edit to docs/review-and-fix-budget.md"
assert_eq "#624 A6d the review-and-fix budget item forces exit 1" "1" "$(_ra_rc "$RA_A6D")"
# The sibling row must stay CLEAN on this fixture: only the review-and-fix bundle moved.
# Without this, a watch_globs typo aiming the new row at the review bundle would satisfy
# every assertion above while the two rows silently watched the same files.
_ra_has "#624 A6d the review-bundle row stays clean when only review-and-fix moved" "$RA_A6D" \
  "[review-bundle-budget] clean"
_ra_live_unchanged "#624 A6d live manifest byte-unchanged after the review-and-fix drift run"

# ── A6d2 — an UNTRACKED review-and-fix member also trips its row (the A6b mirror) ─
# A6b drives the review-bundle row's `git ls-files --others` leg. That leg is now shared
# code parameterized by `row`, so the residual risk is low — but this is the same
# residual-symmetry argument A5i4 makes, one leg further: a brand-new reference that has
# not been `git add`ed is the precedented edit shape a tracked-only diff misses.
RA_A6D2="$_ra_tmp_root/a6d2"; _ra_fixture "$RA_A6D2"
# No _ra_reconcile: a brand-new reference file is an unclassified asset the closure and the
# census both reject by design, so the ATTRIBUTABLE assertion is the budget JUDGMENT line.
printf '# scratch\n' > "$RA_A6D2/skills/review-and-fix/references/reference-9-fixture.md"
_ra_run "$RA_A6D2"
_ra_has "#624 A6d2 an untracked review-and-fix member trips its own budget judgment item" "$RA_A6D2" \
  "[review-and-fix-budget] JUDGMENT"
_ra_has "#624 A6d2 the untracked member is named as the changed member" "$RA_A6D2" \
  "changed members: skills/review-and-fix/references/reference-9-fixture.md"
_ra_has "#624 A6d2 the review-bundle row stays clean when only review-and-fix moved" "$RA_A6D2" \
  "[review-bundle-budget] clean"
assert_eq "#624 A6d2 the untracked-member budget item forces exit 1" "1" "$(_ra_rc "$RA_A6D2")"
_ra_live_unchanged "#624 A6d2 live manifest byte-unchanged after the untracked-member run"

# ── A6e — a touched review-and-fix record resolves its budget item (issue #624) ─
RA_A6E="$_ra_tmp_root/a6e"; _ra_fixture "$RA_A6E"
printf '\n<!-- #624 raf bundle drift -->\n' >> "$RA_A6E/skills/review-and-fix/references/fixing.md"
_ra_reconcile "$RA_A6E"
printf '\n<!-- #624 raf record updated -->\n' >> "$RA_A6E/docs/review-and-fix-budget.md"
_ra_run "$RA_A6E"
_ra_has "#624 A6e a branch that updated the review-and-fix record gets an informational line" "$RA_A6E" \
  "[review-and-fix-budget] INFO bundle members changed"
# The sibling row must stay clean here too — same anti-vacuity control A6d carries. Without
# it this arm's only corroboration is rc 0, which a fixture where NEITHER row noticed
# anything also produces, so the pair would be asymmetric in exactly the direction that
# hides a mis-aimed watch list.
_ra_has "#624 A6e the review-bundle row stays clean when only review-and-fix moved" "$RA_A6E" \
  "[review-bundle-budget] clean"
assert_eq "#624 A6e a branch that updated the review-and-fix record runs clean" "0" "$(_ra_rc "$RA_A6E")"
_ra_live_unchanged "#624 A6e live manifest byte-unchanged after the resolved-record run"

# ── A5o — an UNRESOLVABLE module registry is infrastructure, not "add the rows" ─
# The coverage row's `[arm8] ` marker was declared but unpinned (issue #624): A5j drives
# the sibling `[arm4] ` (coverage-map) leg only. Arm 8 is the registry leg. The fixture
# plants ABSENCE (`rm -f`) rather than an unreadable file, because the guard renders both
# through the same `[arm8] registry unreadable: …` text and absence needs no permission
# bits — the same determinism reason A5m plants malformed JSON. Either way the guard exits
# 1, byte-identically to a real ratchet violation, so without the marker the row would
# report a judgment item telling the agent to add coverage rows keyed on a registry the
# guard could not read.
RA_A5O="$_ra_tmp_root/a5o"; _ra_fixture "$RA_A5O"
rm -f "$RA_A5O/scripts/workflow-flight-recorder-registry.json"
_ra_run "$RA_A5O"
assert_eq "#624 A5o an unreadable module registry exits 2, never 1" "2" "$(_ra_rc "$RA_A5O")"
_ra_has "#624 A5o the unreadable registry is attributed to its own row" "$RA_A5O" \
  "[coverage-map-ratchet] INFRASTRUCTURE"
# The RENDERED discriminator (`matched '…'` is emitted ONLY by run_row's marker-hit
# branch), never the bare payload — which also appears in the row's echoed command output
# and would therefore pass with the marker deleted and the row classified JUDGMENT. Same
# discipline as A5k/A5m.
_ra_has "#624 A5o the unreadable registry is matched by its own arm8 marker" "$RA_A5O" \
  "matched '[arm8] '"
_ra_live_unchanged "#624 A5o live manifest byte-unchanged after the unreadable-registry run"

# ── A5p2 — an UNREADABLE census JSON input is infrastructure, not baseline drift ─
# The census row's `: unreadable:` marker was declared but unpinned (issue #624): A5m
# drives its sibling `: malformed JSON:` leg only, and the two are DIFFERENT census arms
# (a JSON parse failure vs. an OSError on the read itself). Making the manifest a
# DIRECTORY raises IsADirectoryError deterministically, with no permission bits — the
# same reason A5m plants malformed JSON rather than chmod-ing a file.
RA_A5P2="$_ra_tmp_root/a5p2"; _ra_fixture "$RA_A5P2"
rm -f "$RA_A5P2/lib/test/prompt-mass-manifest.json"
mkdir -p "$RA_A5P2/lib/test/prompt-mass-manifest.json"
_ra_run "$RA_A5P2"
assert_eq "#624 A5p2 an unreadable census input exits 2, never 1" "2" "$(_ra_rc "$RA_A5P2")"
_ra_has "#624 A5p2 the unreadable census input is attributed to its own row" "$RA_A5P2" \
  "[prompt-mass-baseline] INFRASTRUCTURE"
# Rendered discriminator, same reason as A5k/A5m/A5o above.
_ra_has "#624 A5p2 the unreadable census input is matched by its own marker" "$RA_A5P2" \
  "matched ': unreadable:'"
_ra_live_unchanged "#624 A5p2 live manifest byte-unchanged after the unreadable-census-input run"

# ── #624 registry invariant — is_budget_row's documented coincidence, pinned ──────
# `is_budget_row` keys on `watch_literals` rather than the "has no argv" proxy, and its
# docstring says the two coincide only because every command-less row today IS a budget
# row. That is a claim about the registry, and nothing asserted it: the predicate's own
# arms are driven by every other arm here, but the coincidence it warns about is not. Pin
# it so the day a command-less non-budget row (or a budget row that gains an argv) lands,
# the suite says so — rather than the docstring quietly becoming false.
# The probe reports its own population and fails closed on an EMPTY registry: every other
# new assertion here carries a non-empty precondition, and this is the only one whose whole
# population comes from inside Python — an empty (or lazily-populated) ROWS would print
# nothing and pass green having checked zero rows. It also pins the full budget-row KEY SET,
# not just the argv coincidence: `budget_row`/`watch_list` also consume `record` and
# `watch_globs`, so a row carrying `watch_literals` alone satisfies a narrower pin and then
# raises KeyError at use — fail-closed, but as a traceback rather than a named breadcrumb.
RA_INVARIANT="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ra", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
if not m.ROWS:
    print("registry is empty — the invariant would check zero rows"); raise SystemExit(0)
bad = []
for r in m.ROWS:
    if m.is_budget_row(r) != (r["argv"] is None):
        bad.append(r["name"] + ":argv-coincidence")
    if m.is_budget_row(r):
        missing = {"record", "watch_literals", "watch_globs"} - set(r)
        if missing:
            bad.append(r["name"] + ":missing-" + ",".join(sorted(missing)))
print(",".join(bad))
' "$RA_HELPER" 2>&1)"
assert_eq "#624 A4b every registry row satisfies the budget-row shape invariant" "" "$RA_INVARIANT"

# ── Helper-content contracts (the registration rule and the disclosed non-goals) ─
devflow_module_pin_unique "#619 the helper header carries the registration rule" 'A PR that adds a checked-in generated artifact gated by the suite adds a row to this registry in the same PR.' "$RA_HELPER"
devflow_module_pin_unique "#619 the helper header discloses the excluded hand-maintained inventories" 'DELIBERATELY EXCLUDED as artifact rows, because they are REDUNDANT' "$RA_HELPER"
assert_eq "#619 the helper is stdlib-only (imports no yaml module)" "0" \
  "$(devflow_module_pin_count 'import yaml' "$RA_HELPER")"
devflow_module_pin_unique "#619 the helper states its single-file write scope" 'the only file under the target root this helper writes is' "$RA_HELPER"

# ════════════════════════════════════════════════════════════════════════════
# #655 — the registry as the merge-conflict oracle
# ════════════════════════════════════════════════════════════════════════════
# A merge conflict in a checked-in generated artifact must be regenerated or its source
# reconciled, never hand-merged: hand-merged bytes match no source of truth, and the row's
# own gate then reports them as drift with a remedy pointed at the wrong file. The registry
# emits the artifact PATHS, the resolution CLASS, and the RECIPE so a conflict rule can key
# on `--list` at runtime and never hardcode a path or a command.
#
# Every behavioral pin below mutates a COPY of the helper inside a fixture and re-runs
# `--list` against it, asserting the pinned OUTPUT line flips present->absent. That is
# stronger than a source-content pin: it proves the emit is what the mutation kills, not
# merely that a source literal moved. Never mutate the live checkout (the module-wide rule).

RA_C_LIST="$RA_LIST"   # the live `--list` output captured in A4, reused unchanged.
# The same output as a FILE, because devflow_module_pin_count reads a path. Written once
# rather than re-spilled per call site.
RA_C_LIST_F="$_ra_tmp_root/c655-live-list.txt"
printf '%s\n' "$RA_C_LIST" > "$RA_C_LIST_F"

# One mutation harness: copy the pristine fixture, apply a `sed -E` to the helper inside
# it, re-run `--list` there, and report whether `literal` was present before and after.
# A no-op mutation, a sed error, or a `--list` that fails to run are each their own named
# failure — never a silent "absent after", which would let a broken harness certify a pin
# it never actually exercised.
_ra_conflict_red_under() {  # name literal mutation
  local name="$1" literal="$2" mutation="$3" dest before after
  dest="$_ra_tmp_root/c655-$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '-')"
  rm -rf "$dest"; _ra_fixture "$dest"
  if ! sed -E "$mutation" "$RA_HELPER" > "$dest/lib/test/regenerate-artifacts.py" 2>/dev/null; then
    assert_eq "$name" "PASS->FAIL" "mutation-errored"; return 0
  fi
  if cmp -s "$RA_HELPER" "$dest/lib/test/regenerate-artifacts.py"; then
    assert_eq "$name" "PASS->FAIL" "mutation-noop(the pin would prove nothing)"; return 0
  fi
  before="$([ "$(devflow_module_pin_count "$literal" "$RA_C_LIST_F")" -ge 1 ] \
    && printf 'PASS' || printf 'FAIL')"
  # The mutated run's rc is deliberately IGNORED for the after-state: several mutations
  # here are expected to make `--list` fail closed (a raise), and "the line is gone
  # because the helper refused to emit anything" is exactly as much a RED as "the line is
  # gone because the emit was deleted". A separate arm (the fail-closed pin) asserts the
  # raise path on its own terms.
  python3 "$dest/lib/test/regenerate-artifacts.py" --list --repo-root "$dest" \
    >"$dest/.ra.clist" 2>&1
  after="$([ "$(devflow_module_pin_count "$literal" "$dest/.ra.clist")" -ge 1 ] \
    && printf 'PASS' || printf 'FAIL')"
  assert_eq "$name" "PASS->FAIL" "$before->$after"
}

# ── (a) every registered row emits a conflict-class line with an IN-SET value ────
# Derived from RA_ROW_NAMES (the registry's own roster, already coupled to `--list` by
# A4), so a newly-registered row that forgets its class is caught here rather than
# silently omitted from a hand-maintained list.
for _row in $RA_ROW_NAMES; do
  case "$RA_C_LIST" in
    *"conflict-class	$_row	regenerate"*|\
    *"conflict-class	$_row	reconcile-source"*|\
    *"conflict-class	$_row	by-hand"*)
      assert_eq "#655 --list emits an in-set conflict-class for: $_row" yes yes ;;
    *) assert_eq "#655 --list emits an in-set conflict-class for: $_row" yes \
         "no(no conflict-class line, or a value outside {regenerate, reconcile-source, by-hand})" ;;
  esac
  # One conflict-recipe line per row, non-empty — the recipe the conflict rule follows.
  case "$(printf '%s\n' "$RA_C_LIST" | sed -n "s/^conflict-recipe	${_row}	//p")" in
    '') assert_eq "#655 --list emits a non-empty conflict-recipe for: $_row" yes \
          "no(absent or empty)" ;;
    *)  assert_eq "#655 --list emits a non-empty conflict-recipe for: $_row" yes yes ;;
  esac
done
_ra_conflict_red_under "#655 the conflict-class emit is what produces those lines" \
  'conflict-class	coverage-map-ratchet	by-hand' \
  's/^(\s*)print\(f"conflict-class.*$/\1pass/'

# ── (b) the six class ASSIGNMENTS, each pinned; mutation flips one ───────────────
_ra_class_is() {  # row expected-class
  case "$RA_C_LIST" in
    *"conflict-class	$1	$2"*) assert_eq "#655 conflict-class assignment: $1 -> $2" yes yes ;;
    *) assert_eq "#655 conflict-class assignment: $1 -> $2" yes \
         "no($1 is not classified $2)" ;;
  esac
}
_ra_class_is cloud-writer-manifest       regenerate
_ra_class_is prompt-mass-baseline        regenerate
_ra_class_is capability-profile-literals reconcile-source
_ra_class_is review-bundle-budget        by-hand
_ra_class_is review-and-fix-budget       by-hand
_ra_class_is coverage-map-ratchet        by-hand
# The mutation flips every by-hand row to regenerate. The pinned literal is the coverage
# row's assignment — the one whose misclassification is most costly, because
# coverage_map_guard.py has no write path at all, so "regenerate" would name a command
# that does not exist.
_ra_conflict_red_under "#655 a flipped class is caught (by-hand -> regenerate)" \
  'conflict-class	coverage-map-ratchet	by-hand' \
  's/"conflict_class": "by-hand"/"conflict_class": "regenerate"/g'

# ── (c) the conflict-path set covers EVERY known generated artifact ──────────────
# This is the property without which the whole rule is inert: the rule matches a
# conflicted path against these lines, so an artifact absent from the set falls through
# to the hand-merge default — the exact failure the rule exists to prevent. The list is
# the audit's own enumeration of the repo's generated artifacts, deliberately independent
# of the registry (a registry-derived list could only certify its own completeness).
_ra_conflict_path_covered() {  # artifact-path
  case "$RA_C_LIST" in
    *"conflict-path	"*"	$1"*) assert_eq "#655 conflict-path covers the generated artifact: $1" yes yes ;;
    *) assert_eq "#655 conflict-path covers the generated artifact: $1" yes \
         "no($1 is a generated artifact but no conflict-path line names it; a conflict there would take the hand-merge default)" ;;
  esac
}
_ra_conflict_path_covered scripts/devflow-cloud-writer-contract.json
_ra_conflict_path_covered lib/test/prompt-mass-baseline.json
_ra_conflict_path_covered lib/capability-profiles.json
_ra_conflict_path_covered docs/review-bundle-budget.md
_ra_conflict_path_covered docs/review-and-fix-budget.md
_ra_conflict_path_covered lib/test/modules/coverage-map.json
# The generated workflow literals, sourced from the generator's own REGIONS rather than
# re-enumerated in the registry. Pinned by their real paths here so a REGIONS rename that
# silently empties the derivation is caught.
_ra_conflict_path_covered .github/workflows/devflow-runner.yml
_ra_conflict_path_covered .github/workflows/devflow.yml
_ra_conflict_path_covered .github/workflows/devflow-implement.yml
_ra_conflict_path_covered .github/workflows/matcher-probe.yml
_ra_conflict_red_under "#655 dropping a row's conflict_paths entry leaves its artifact uncovered" \
  'conflict-path	prompt-mass-baseline	lib/test/prompt-mass-baseline.json' \
  's/"conflict_paths": \("lib\/test\/prompt-mass-baseline.json",\)/"conflict_paths": ()/'
# And the generator-sourced half: emptying REGIONS must NOT silently shrink the set.
_ra_conflict_red_under "#655 an empty generator REGIONS list does not silently shrink the path set" \
  'conflict-path	capability-profile-literals	.github/workflows/devflow-runner.yml' \
  's/^REGIONS = \[$/REGIONS = []  # mutated/'

# ── (d) each regenerate/reconcile-source recipe names a command the TOOL really has ──
# A substring pin ("the recipe mentions --write-baseline") stays green when the flag is
# renamed in the tool and the recipe goes dead. So the needle is checked against the
# tool's REAL interface: its `--help` text, or — for the capability generator, which has
# no argparse and rejects `--help` — an actual fixture run of the bare write form.
_ra_recipe_names() {  # row needle
  case "$(printf '%s\n' "$RA_C_LIST" | sed -n "s/^conflict-recipe	${1}	//p")" in
    *"$2"*) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}
# `--help` is captured from a FIXTURE copy so a mutated-tool arm below can rename the flag
# without touching the live checkout.
# The third argument is a `case` GLOB, not a plain substring, because a bare
# `*--write-baseline*` also matches `--write-baseline-renamed` — so the renamed-flag
# mutation would stay green and the pin would prove nothing. Callers append a `[!-]`
# boundary class so a longer flag with the same prefix does NOT satisfy the check.
# argparse's help is ANSI-colored here, so the boundary character is commonly an escape
# byte rather than a space; `[!-]` accepts either and only excludes the hyphen that a
# renamed sibling flag would carry.
_ra_tool_has_flag() {  # root tool-relative-path case-glob
  # shellcheck disable=SC2254  # the expansion IS the pattern — see the note above.
  case "$(cd "$1" && python3 "$2" --help 2>&1)" in
    $3) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}
RA_IFACE="$_ra_tmp_root/iface"; _ra_fixture "$RA_IFACE"
assert_eq "#655 recipe interface: cloud-writer names the 'generate' subcommand the tool declares" \
  "yes/yes" \
  "$(_ra_recipe_names cloud-writer-manifest 'cloud_writer_contract.py generate')/$(_ra_tool_has_flag "$RA_IFACE" lib/test/cloud_writer_contract.py '*generate[!a-z-]*')"
assert_eq "#655 recipe interface: prompt-mass names the '--write-baseline' writer the tool declares" \
  "yes/yes" \
  "$(_ra_recipe_names prompt-mass-baseline '--write-baseline')/$(_ra_tool_has_flag "$RA_IFACE" lib/test/prompt-mass-census.py '*--write-baseline[!-]*')"
# The capability generator has no argparse (it rejects `--help`), so its interface is
# established by RUNNING the bare write form the recipe names against a fixture: an exit
# outside {0} — or an "unknown argument" breadcrumb — means the recipe names a dead form.
RA_CAPGEN_OUT="$(cd "$RA_IFACE" && python3 lib/generate-capability-profiles.py 2>&1)"; RA_CAPGEN_RC=$?
case "$RA_CAPGEN_RC/$RA_CAPGEN_OUT" in
  0/*unknown\ argument*|[!0]/*)
    assert_eq "#655 recipe interface: the capability generator's bare write form really runs" yes \
      "no(rc=$RA_CAPGEN_RC; output: $RA_CAPGEN_OUT)" ;;
  *) assert_eq "#655 recipe interface: the capability generator's bare write form really runs" yes yes ;;
esac
assert_eq "#655 recipe interface: the capability recipe names the generator and both coupled files" \
  "yes/yes/yes" \
  "$(_ra_recipe_names capability-profile-literals 'lib/generate-capability-profiles.py')/$(_ra_recipe_names capability-profile-literals 'lib/capability-profiles.json')/$(_ra_recipe_names capability-profile-literals 'lib/review-profile.tokens')"
# The mutation the round-2 finding demands: rename the flag IN THE TOOL and confirm the
# interface check goes RED. A substring-only pin stays green here — that is the whole
# point of driving it against the tool's real `--help`.
RA_IFACE_MUT="$_ra_tmp_root/iface-mut"; _ra_fixture "$RA_IFACE_MUT"
sed -i.bak 's/write-baseline/write-baseline-renamed/g' \
  "$RA_IFACE_MUT/lib/test/prompt-mass-census.py" 2>/dev/null
assert_eq "#655 renaming --write-baseline in the tool turns the interface check RED" \
  "no" "$(_ra_tool_has_flag "$RA_IFACE_MUT" lib/test/prompt-mass-census.py '*--write-baseline[!-]*')"

# ── (e) exactly ONE conflict-sibling line, naming the reviewer lock ──────────────
assert_eq "#655 --list emits exactly one conflict-sibling line" "1" \
  "$(devflow_module_pin_count 'conflict-sibling	' "$RA_C_LIST_F")"
assert_eq "#655 the conflict-sibling line names the reviewer lock as by-hand" "1" \
  "$(devflow_module_pin_count 'conflict-sibling	capability-profile-literals	lib/review-profile.tokens	by-hand' "$RA_C_LIST_F")"
_ra_conflict_red_under "#655 the coupled_by_hand tuple is what produces the sibling line" \
  'conflict-sibling	capability-profile-literals	lib/review-profile.tokens	by-hand' \
  's/"coupled_by_hand": \(\("lib\/review-profile.tokens", "by-hand"\),\)/"coupled_by_hand": ()/'

# ── (f) a conflict_class outside the closed set FAILS CLOSED ─────────────────────
# The bind-time validation raises, so `--list` never emits an unknown class a consumer
# would have no route for. Driven end-to-end: rc must be non-zero and the breadcrumb must
# name the offending value, not merely traceback anonymously.
RA_C655F="$_ra_tmp_root/c655-outofset"; _ra_fixture "$RA_C655F"
sed -E 's/"conflict_class": "regenerate"/"conflict_class": "hand-wave"/' "$RA_HELPER" \
  > "$RA_C655F/lib/test/regenerate-artifacts.py"
python3 "$RA_C655F/lib/test/regenerate-artifacts.py" --list --repo-root "$RA_C655F" \
  >"$RA_C655F/.ra.out" 2>&1; printf '%s\n' "$?" >"$RA_C655F/.ra.rc"
case "$(_ra_rc "$RA_C655F")" in
  0) assert_eq "#655 an out-of-set conflict_class fails closed (non-zero exit)" yes \
       "no(--list exited 0 and emitted an unknown class)" ;;
  *) assert_eq "#655 an out-of-set conflict_class fails closed (non-zero exit)" yes yes ;;
esac
_ra_has "#655 the out-of-set breadcrumb names the offending value" "$RA_C655F" "'hand-wave'"
_ra_has "#655 the out-of-set breadcrumb names the closed set" "$RA_C655F" "which is outside"
# And the sibling invariant: an empty recipe is refused on the same bind pass.
RA_C655F2="$_ra_tmp_root/c655-emptyrecipe"; _ra_fixture "$RA_C655F2"
sed -E 's/^        "policy": "add the missing coverage rows.*$/        "policy": "",/' "$RA_HELPER" \
  > "$RA_C655F2/lib/test/regenerate-artifacts.py"
python3 "$RA_C655F2/lib/test/regenerate-artifacts.py" --list --repo-root "$RA_C655F2" \
  >"$RA_C655F2/.ra.out" 2>&1; printf '%s\n' "$?" >"$RA_C655F2/.ra.rc"
case "$(_ra_rc "$RA_C655F2")" in
  0) assert_eq "#655 an empty recipe fails closed (non-zero exit)" yes \
       "no(--list exited 0 with a row carrying no recipe)" ;;
  *) assert_eq "#655 an empty recipe fails closed (non-zero exit)" yes yes ;;
esac
_ra_has "#655 the empty-recipe breadcrumb names the recipe field" "$RA_C655F2" "empty recipe (policy)"

# ── (g) the recipe is a SINGLE source: `policy`, read by BOTH consumers ──────────
# A parallel `conflict_recipe` field would let the batched pass and the conflict rule
# drift — the coupled-mirror hazard. Two halves: no such field exists, and the string the
# batched pass prints as `governing policy:` is byte-identical to the `conflict-recipe`
# line for the same row.
assert_eq "#655 no parallel conflict_recipe field exists (the recipe is the reused policy)" "0" \
  "$(devflow_module_pin_count 'conflict_recipe' "$RA_HELPER")"
# A3 already ran a fixture whose capability row emitted a JUDGMENT with its governing
# policy; compare that rendered text against this row's conflict-recipe line. Both are
# derived from the live registry, so a split into two fields breaks the equality.
RA_C655G_RECIPE="$(printf '%s\n' "$RA_C_LIST" | sed -n 's/^conflict-recipe	capability-profile-literals	//p')"
case "$RA_C655G_RECIPE" in
  '') assert_eq "#655 the capability conflict-recipe is non-empty (single-source test is live)" yes \
        "no(empty — the comparison below would be vacuous)" ;;
  *)  assert_eq "#655 the capability conflict-recipe is non-empty (single-source test is live)" yes yes ;;
esac
_ra_has "#655 the batched pass prints the SAME recipe string as governing policy" "$RA_A3" \
  "governing policy: $RA_C655G_RECIPE"

# ── Surface-presence pins: the rule copies and the arm pointers ──────────────────
# `assert_pin_unique`-class presence checks (no mutation obligation): these assert that a
# coupled prose mirror is present and identical, not that a behavior flips.
RA_EXT_DIR="$RA_REPO/.devflow/prompt-extensions"
RA_RULE_HEADING='## Merge conflicts in generated artifacts'
for _ext in implement review-and-fix receiving-code-review; do
  devflow_module_pin_unique "#655 the conflict rule has its own section in $_ext.md" \
    "$RA_RULE_HEADING" "$RA_EXT_DIR/$_ext.md"
  devflow_module_pin_unique "#655 the conflict rule cites --list as the oracle in $_ext.md" \
    'python3 lib/test/regenerate-artifacts.py --list' "$RA_EXT_DIR/$_ext.md"
done
# Byte-identity across the three copies: extract each section (heading to the next `## `)
# and require all three to be equal. A per-file presence pin cannot catch a copy that
# drifted in its body.
_ra_rule_body() {  # file
  sed -n "/^${RA_RULE_HEADING}\$/,/^## /p" "$1" | sed '$d'
}
RA_RULE_IMPL="$(_ra_rule_body "$RA_EXT_DIR/implement.md")"
case "$RA_RULE_IMPL" in
  '') assert_eq "#655 the extracted conflict-rule section is non-empty (identity test is live)" yes \
        "no(empty — the byte-identity comparisons below would be vacuous)" ;;
  *)  assert_eq "#655 the extracted conflict-rule section is non-empty (identity test is live)" yes yes ;;
esac
assert_eq "#655 the conflict rule is byte-identical in review-and-fix.md" \
  "$RA_RULE_IMPL" "$(_ra_rule_body "$RA_EXT_DIR/review-and-fix.md")"
assert_eq "#655 the conflict rule is byte-identical in receiving-code-review.md" \
  "$RA_RULE_IMPL" "$(_ra_rule_body "$RA_EXT_DIR/receiving-code-review.md")"
# The rule lives OUTSIDE the Batched-artifact-regeneration section: that section's trigger
# is post-edit/pre-suite, which no in-run conflict arm ever routes through — placing the
# rule only there is what would leave the conflict handler unwired.
assert_eq "#655 the conflict rule is its own top-level section, not nested under Batched" "1" \
  "$(devflow_module_pin_count "$RA_RULE_HEADING" "$RA_EXT_DIR/implement.md")"
# The narrow prompt-mass conflict sentence is retired in favour of the generalized rule;
# a surviving second statement of the same decision is the coupled-mirror defect.
assert_eq "#655 the superseded narrow prompt-mass conflict sentence is gone" "0" \
  "$(devflow_module_pin_count 'Resolve such a conflict by regenerating the complete' "$RA_EXT_DIR/implement.md")"

# The generic, repo-agnostic pointer each in-run conflict arm carries. It names no
# DevFlow-internal helper, so it stays correct in the vendored/shipped surfaces.
RA_ARM_POINTER='When the conflict is in a checked-in generated or derived artifact, do not hand-merge its bytes — regenerate the artifact or reconcile its source of truth per your repo'
devflow_module_pin_unique "#655 the implement checkpoint CONFLICT arm carries the generic pointer" \
  "$RA_ARM_POINTER" "$RA_REPO/skills/implement/phases/phase-1-setup.md"
devflow_module_pin_unique "#655 the review-and-fix CONFLICT arm carries the generic pointer" \
  "$RA_ARM_POINTER" "$RA_REPO/skills/review-and-fix/references/fixing.md"
devflow_module_pin_unique "#655 the receiving-code-review branch-update arm carries the generic pointer" \
  "$RA_ARM_POINTER" "$RA_REPO/skills/receiving-code-review/SKILL.md"
# The vendored skill ships to consumers, so its pointer must name no DevFlow-internal
# helper — the same repo-agnostic boundary its upstream MIT body already carries.
assert_eq "#655 the vendored receiving-code-review pointer names no DevFlow-internal helper" "0" \
  "$(devflow_module_pin_count 'regenerate-artifacts.py' "$RA_REPO/skills/receiving-code-review/SKILL.md")"
