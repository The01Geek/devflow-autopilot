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
  ( cd "$1" && python3 lib/test/cloud_writer_contract.py generate >/dev/null 2>&1
    python3 lib/test/prompt-mass-census.py --write-baseline >.ra-baseline.tmp 2>/dev/null \
      && mv .ra-baseline.tmp lib/test/prompt-mass-baseline.json ) >/dev/null 2>&1
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
RA_ROW_NAMES="cloud-writer-manifest capability-profile-literals prompt-mass-baseline review-bundle-budget coverage-map-ratchet"

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
# The watch list is compared against the DISK-derived bundle member set, never against
# the monolith's $REVIEW_ROOT/$REVIEW_PHASE_STEMS/$RB_EXT variables — those are unset
# under standalone run-module.sh execution, which would make the comparison vacuous
# exactly where the module is run alone. The disk set is already coupled to what the
# monolith measures by run.sh's issue-529 pin that phases/ matches REVIEW_PHASE_STEMS,
# so this coupling is transitive.
RA_WATCH_HELPER="$(printf '%s\n' "$RA_LIST" | sed -n 's/^budget-watch	//p' | sort)"
RA_WATCH_DISK="$( { printf '%s\n' "skills/review/SKILL.md" ".devflow/prompt-extensions/review.md"
  ( cd "$RA_REPO" && ls skills/review/phases/*.md ); } | sort )"
assert_eq "#619 A4 --list watch list equals the disk-derived bundle membership" \
  "$RA_WATCH_DISK" "$RA_WATCH_HELPER"

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
assert_eq "#619 A5 exit 2 takes precedence over a concurrent judgment item" "2" "$(_ra_rc "$RA_A5P")"
_ra_live_unchanged "#619 A5 live manifest byte-unchanged after the precedence run"

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
mv "$RA_A5E/.devflow/prompt-extensions/review.md" "$RA_A5E/.devflow/prompt-extensions/review-renamed.md"
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
python3 "$RA_HELPER" --list --repo-root "$RA_A5E" > "$RA_A5E/.ra.list" 2>&1
assert_eq "#619 A5e --list discloses the missing member" "1" \
  "$(devflow_module_pin_count 'budget-watch-missing	.devflow/prompt-extensions/review.md' "$RA_A5E/.ra.list")"
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

# ── A5f — default_repo_root anchors its probe to THIS checkout, not the process cwd ──
# The helper's one write target is a tracked file, so a root resolved from an unrelated
# repository would regenerate that repository's manifest. Nothing exercised the anchor:
# every other arm passes --repo-root explicitly, so deleting `cwd=str(here)` left all
# assertions green. Run --list with NO --repo-root from inside an unrelated git repo and
# assert the watch list is still DevFlow's own bundle.
RA_A5F="$_ra_tmp_root/a5f-unrelated"; mkdir -p "$RA_A5F"
( cd "$RA_A5F" && git init -q . && git config user.email a@b.c && git config user.name t \
  && printf 'x\n' > f.txt && git add -A && git commit -q -m unrelated ) >/dev/null 2>&1
( cd "$RA_A5F" && python3 "$RA_HELPER" --list ) > "$RA_A5F/list.out" 2>&1
assert_eq "#619 A5f --list from an unrelated repo still resolves THIS checkout's bundle" "1" \
  "$(devflow_module_pin_count 'budget-watch	skills/review/SKILL.md' "$RA_A5F/list.out")"
assert_eq "#619 A5f the unrelated repo contributes no watch-list member" "0" \
  "$(devflow_module_pin_count 'budget-watch	f.txt' "$RA_A5F/list.out")"
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
# the exit-1 assertion below corroborates it but does not attribute it (A3 is what
# pins "a judgment item forces exit 1" on its own).
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

# ── Helper-content contracts (the registration rule and the disclosed non-goals) ─
devflow_module_pin_unique "#619 the helper header carries the registration rule" 'A PR that adds a checked-in generated artifact gated by the suite adds a row to this registry in the same PR.' "$RA_HELPER"
devflow_module_pin_unique "#619 the helper header discloses the excluded hand-maintained inventories" 'are hand-maintained inventories with no standalone check command' "$RA_HELPER"
assert_eq "#619 the helper is stdlib-only (imports no yaml module)" "0" \
  "$(devflow_module_pin_count 'import yaml' "$RA_HELPER")"
devflow_module_pin_unique "#619 the helper states its single-file write scope" 'the only file under the target root this helper writes is' "$RA_HELPER"
