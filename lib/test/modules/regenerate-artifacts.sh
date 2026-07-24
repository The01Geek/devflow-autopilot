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
# The boolean sibling of _ra_same: one assertion whose pass and fail arms are spelled
# once, so a caller cannot register two differently-named assertions by drifting the
# name text between its own two `assert_eq` calls.
_ra_ok() {  # name ok-flag fail-detail   (ok-flag: "yes" passes, anything else fails)
  if [ "$2" = yes ]; then assert_eq "$1" yes yes; else assert_eq "$1" yes "no($3)"; fi
}
# Substring-presence over a FILE. `_ra_has` (which takes a fixture root and reads its
# `.ra.out`) delegates here, so the count-unestablished arm and the output dump exist
# once rather than being re-spelled by every caller that already holds a path.
_ra_has_file() {  # name file substring
  local n
  n="$(devflow_module_pin_count "$3" "$2")"
  case "$n" in
    ''|*[!0-9]*) assert_eq "$1" yes "no(count unestablished for '$3')"; return 0 ;;
  esac
  if [ "$n" -ge 1 ]; then assert_eq "$1" yes yes
  else assert_eq "$1" yes "no('$3' absent; output: $(tr '\n' '|' <"$2"))"; fi
}
# Extract one `key=value` field from a builder/oracle summary line with bash parameter
# expansion (never `cut`/`awk` — the un-guaranteed-tool rule), so an assertion pins the
# field it cares about rather than the summary line's printf order.
# The match is anchored on a leading SPACE boundary (the summary is space-prefixed
# first), because an unanchored `${1#*"$2"=}` would let `missing` match inside
# `skip_missing=` and silently return the wrong field's value — which would land on the
# real key only by accident of printf order, the exact property this helper exists to
# stop an assertion depending on. An absent key returns the sentinel `unset`, which is
# equal to no expected count and so fails loudly rather than reading as zero.
_ra_field() {  # summary key
  local _s=" $1" _rest
  _rest="${_s#* "$2"=}"
  [ "$_rest" != "$_s" ] || { printf 'unset'; return 0; }
  printf '%s' "${_rest%% *}"
}
# `_ra_same` over two DERIVED field values: an absent key on both sides would otherwise
# compare `unset` to `unset` and pass, so the sentinel is rejected before the compare.
# That is reachable by exactly the coupled-mirror rename the oracle's header warns about.
_ra_same_field() {  # name expected-summary actual-summary key fail-detail
  local _e _a
  _e="$(_ra_field "$2" "$4")"; _a="$(_ra_field "$3" "$4")"
  if [ "$_e" = unset ] || [ "$_a" = unset ]; then
    assert_eq "$1" yes "no(field '$4' is absent from a summary — $5)"
    return 0
  fi
  _ra_same "$1" "$_e" "$_a" "$5"
}
# Seed a temp git repository with the module's fixture identity. The index-state repos
# below share it, so a future `git config` addition is a one-line change. `rerere` is
# disabled explicitly: it is inherited from the developer's global config and would
# auto-resolve the conflicted-index fixture, silently emptying the arm that fixture
# exists to exercise. Returns the seeding rc so a caller never builds on a dead repo.
_ra_seed_repo() {  # dir [git-init-flags...]
  local _d="$1"; shift
  mkdir -p "$_d" || return 1
  (
    cd "$_d" || exit 1
    git init -q "$@" . &&
    git config user.email devflow@example.invalid &&
    git config user.name devflow &&
    git config rerere.enabled false
  ) >/dev/null 2>&1
}

# ────────────────────────────────────────────────────────────────────────────
echo "#619 batched generated-artifact regeneration pass (lib/test/regenerate-artifacts.py)"
# ────────────────────────────────────────────────────────────────────────────

# One pristine fixture is built once and copied per assertion: each copy is a full
# repository image (the generators resolve their roots from __file__ or an argv root,
# so a partial tree would exercise the wrong closure), and rebuilding it per
# assertion would dominate the module's runtime.
#
# The image is built from the git INDEX — every tracked path, copied file by file at
# its own relative path, with its mode taken from the index (issue #714). Two rules,
# both load-bearing:
#   * COMPLETE, never a hand-picked subset — the capability generator reads its manifest
#     and workflows, the cloud-writer closure reads skills/ and scripts/, and a subset
#     that misses one makes the *pristine* fixture drift, silently invalidating every "no other row
#     drifted" premise in this module.
#   * TRACKED-ONLY — nothing untracked can enter the image, which is why this module
#     needs no `__pycache__`/`.ruff_cache`/`.devflow/tmp` prune step.
# The history behind the tracked-only rule and the measured cost it removed live in
# regenerate-artifacts.inventory.md; do not restate the figures here.
#
# `git ls-files -s` (preflight-guaranteed) makes the selection and bash parameter
# expansion does the path arithmetic — never `cut`/`sort`/`awk`, a non-preflight PATH
# tool must not decide WHICH files get copied (CLAUDE.md's un-guaranteed-tool rule):
# a missing tool would yield an empty entry list and a hollow fixture.
#
# Build a tracked-only repository image. Prints one `key=value` summary line so a
# caller can assert completeness against the FULL index denominator; each of the three
# skip arms is taken with its own distinct named stderr breadcrumb and subtracted from
# that denominator by name, never failing the build.
#
# UNKNOWN IS NOT ZERO — the same rule the python oracle below states, honored here so
# the two halves of the coupled mirror behave alike. The index enumeration is written
# to a file and its rc CHECKED, never read through a process substitution whose rc is
# unobservable: a broken `git`, a `<src-repo>` that is not a repository, or an
# unreadable index would otherwise yield an empty read and print
# `total=0 copied=0 ...`, a vacuous clean indistinguishable from a legitimately empty
# index — and `_ra_summary_balances` would certify it (0 == 0+0+...). Print an
# `unestablished` sentinel and return 1 instead, which equals no expected count and so
# fails loudly at whichever assertion consumes the summary.
_ra_build_image() {  # <src-repo> <dest>
  local _src="$1" _dest="$2"
  local _rec _mode _path _prev='' _total=0 _copied=0 _tab _idx _mk
  local _skip_missing=0 _skip_gitlink=0 _skip_symlink=0 _fail_copy=0 _fail_mode=0
  _tab=$'\t'
  mkdir -p "$_dest" || return 1
  _idx="$_dest.index"
  if ! (cd "$_src" && git ls-files -s -z) >"$_idx" 2>/dev/null; then
    printf 'regenerate-artifacts fixture: could not establish the index for %s (git ls-files -s -z failed)\n' "$_src" >&2
    printf 'total=unestablished copied=unestablished fail_copy=unestablished fail_mode=unestablished skip_missing=unestablished skip_gitlink=unestablished skip_symlink=unestablished\n'
    rm -f "$_idx"
    return 1
  fi
  while IFS= read -r -d '' _rec; do
    [ -n "$_rec" ] || continue
    # `<mode> <sha> <stage>\t<path>` — the path is read whole after the TAB, so a
    # newline or a space in a filename cannot split one entry into two (-z).
    _mode="${_rec%% *}"
    _path="${_rec#*"$_tab"}"
    # Unmerged paths appear once per stage (1/2/3), contiguously: count and copy the
    # path once, so the denominator and the image agree on a conflicted tree.
    [ "$_path" != "$_prev" ] || continue
    _prev="$_path"
    _total=$((_total + 1))
    case "$_mode" in
      160000)
        printf 'regenerate-artifacts fixture: skipping gitlink index entry %s\n' "$_path" >&2
        _skip_gitlink=$((_skip_gitlink + 1)); continue ;;
      120000)
        printf 'regenerate-artifacts fixture: skipping symlink index entry %s\n' "$_path" >&2
        _skip_symlink=$((_skip_symlink + 1)); continue ;;
    esac
    if [ ! -f "$_src/$_path" ]; then
      printf 'regenerate-artifacts fixture: skipping index entry with no working-tree file %s\n' "$_path" >&2
      _skip_missing=$((_skip_missing + 1)); continue
    fi
    # `${var%/*}` returns the WHOLE string when the value has no `/`, so an unguarded
    # mkdir would create a DIRECTORY named CLAUDE.md where a regular file must be, drifting
    # the pristine fixture. Guard on `*/*`.
    # A copy that FAILS is not a skip: it is counted and breadcrumbed on its own
    # `fail_copy` channel, never swallowed into the gap between `total` and `copied`.
    # Neither `mkdir` nor `cp` is preflight-guaranteed, so each is failure-checked on
    # its own step — `mkdir` through the `_mk` flag, `cp` in the `if` — rather than
    # relying on the `cp` to inherit the `mkdir`'s failure. An rc-127 host is therefore
    # counted and breadcrumbed instead of silently producing a hollow image, and the
    # parent-directory failure is attributable to the step that actually failed.
    _mk=0
    case "$_path" in */*) mkdir -p "$_dest/${_path%/*}" || _mk=1 ;; esac
    if [ "$_mk" -ne 0 ] || ! cp "$_src/$_path" "$_dest/$_path"; then
      printf 'regenerate-artifacts fixture: FAILED to copy tracked entry %s\n' "$_path" >&2
      _fail_copy=$((_fail_copy + 1)); continue
    fi
    # The mode comes from the INDEX, not the working tree: on a core.fileMode=false
    # checkout (git's default on Windows) the index records 100755 while the on-disk
    # file carries no executable bit, and inheriting that bit would turn the module RED.
    # `chmod` is not preflight-guaranteed either, and a mode that silently failed to
    # apply is exactly the defect this block exists to stop — so it gets its own
    # `fail_mode` channel rather than being counted as a clean copy. The entry stays on
    # disk (the oracle compares path sets, so it is neither `extra` nor `missing`); only
    # the accounting says the mode was not established.
    if ! case "$_mode" in
           100755) chmod 755 "$_dest/$_path" ;;
           *)      chmod 644 "$_dest/$_path" ;;
         esac; then
      printf 'regenerate-artifacts fixture: FAILED to set index mode %s on %s\n' "$_mode" "$_path" >&2
      _fail_mode=$((_fail_mode + 1)); continue
    fi
    _copied=$((_copied + 1))
  done <"$_idx"
  rm -f "$_idx"
  printf 'total=%s copied=%s fail_copy=%s fail_mode=%s skip_missing=%s skip_gitlink=%s skip_symlink=%s\n' \
    "$_total" "$_copied" "$_fail_copy" "$_fail_mode" "$_skip_missing" "$_skip_gitlink" "$_skip_symlink"
}
# Every de-duplicated index entry the builder saw must be accounted for exactly once —
# copied, failed, or skipped by a named arm. Without this the `cp`/`mkdir` failure arm
# would be a silent shortfall detectable only by the oracle, and the oracle is the very
# thing this pairing exists to stop the module depending on alone.
_ra_summary_balances() {  # name summary
  local _t _sum _k
  _t="$(_ra_field "$2" total)"; _sum=0
  for _k in copied fail_copy fail_mode skip_missing skip_gitlink skip_symlink; do
    case "$(_ra_field "$2" "$_k")" in
      ''|*[!0-9]*) assert_eq "$1" yes "no(field '$_k' unusable in summary: $2)"; return 0 ;;
      *) _sum=$((_sum + $(_ra_field "$2" "$_k"))) ;;
    esac
  done
  _ra_same "$1" "$_t" "$_sum" "total does not equal copied+fail_copy+fail_mode+skips — summary: $2"
}

_ra_pristine="$_ra_tmp_root/pristine"
# The live-checkout build's stderr is CAPTURED, not discarded: it is the one build whose
# breadcrumbs name real repository paths, so a skip arm firing on the live index (a newly
# tracked symlink or submodule) or a copy failure must be readable, not merely counted.
_ra_pristine_err="$_ra_tmp_root/pristine.err"
_ra_pristine_summary="$(_ra_build_image "$RA_REPO" "$_ra_pristine" 2>"$_ra_pristine_err")"
# ── Fixture-builder contract (issue #714) ───────────────────────────────────
# An INDEPENDENT oracle, deliberately not sharing the builder's own bookkeeping: it
# re-reads the index itself and diffs the resulting expectation against the files
# actually on disk under the image. `extra` catches untracked content riding in;
# `missing` catches a silently-dropped mode — the denominator is the FULL de-duplicated
# index, so dropping a mode fails the count instead of shrinking both sides together.
# These run BEFORE the `git init` below, so the image carries no `.git/` of its own yet.
#
# COUPLED MIRROR: this oracle re-states `_ra_build_image`'s selection policy (mode
# triage, unmerged-stage de-duplication, the working-tree isfile check) in a second
# language. That independence is the point — but it means a change to the builder's
# skip policy MUST be made here in the same commit, or the oracle silently keeps
# certifying the old policy. Edit the two together; the inventory records the pair.
_ra_image_report() {  # <src-repo> <image>  → "extra=N missing=N skip_missing=N skip_gitlink=N skip_symlink=N"
  python3 - "$1" "$2" <<'RA_PY'
import os, subprocess, sys
src, image = sys.argv[1], sys.argv[2]
# UNKNOWN IS NOT ZERO. A failed `git ls-files` (broken git, `src` not a repository, an
# unreadable index — every one of which also empties the image) would otherwise yield an
# empty expectation AND an empty actual, printing `extra=0 missing=0`: a vacuous clean
# from the one artifact whose whole job is to catch the builder lying. Emit an
# `unestablished` sentinel instead, which equals no expected count and so fails loudly.
_r = subprocess.run(["git", "ls-files", "-s", "-z"], cwd=src,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if _r.returncode != 0 or not os.path.isdir(image):
    print("extra=unestablished missing=unestablished skip_missing=unestablished "
          "skip_gitlink=unestablished skip_symlink=unestablished")
    sys.stderr.write("regenerate-artifacts oracle: could not establish the index/image "
                     "for %s -> %s (rc=%d): %s\n"
                     % (src, image, _r.returncode,
                        _r.stderr.decode("utf-8", "replace").strip()))
    sys.exit(0)
raw = _r.stdout.split(b"\0")
seen, expected = set(), set()
skips = {"missing": 0, "gitlink": 0, "symlink": 0}
for rec in raw:
    if not rec:
        continue
    meta, _, path = rec.partition(b"\t")
    mode = meta.split(b" ")[0].decode()
    path = path.decode("utf-8", "surrogateescape")
    if path in seen:
        continue
    seen.add(path)
    if mode == "160000":
        skips["gitlink"] += 1
    elif mode == "120000":
        skips["symlink"] += 1
    elif not os.path.isfile(os.path.join(src, path)):
        skips["missing"] += 1
    else:
        expected.add(path)
actual = set()
for root, _dirs, files in os.walk(image):  # tree-walk-ok: walks the per-test fixture image, never the repository root, so no sibling worktree is reachable from it
    for f in files:
        actual.add(os.path.relpath(os.path.join(root, f), image))
print("extra=%d missing=%d skip_missing=%d skip_gitlink=%d skip_symlink=%d"
      % (len(actual - expected), len(expected - actual),
         skips["missing"], skips["gitlink"], skips["symlink"]))
RA_PY
}

RA_PRISTINE_REPORT="$(_ra_image_report "$RA_REPO" "$_ra_pristine")"
_ra_ok "#619 pristine fixture holds no untracked content" \
  "$([ "$(_ra_field "$RA_PRISTINE_REPORT" extra)" = 0 ] && printf yes)" \
  "untracked paths present: $RA_PRISTINE_REPORT"
# `extra=0` alone is satisfied by an EMPTY image, so it is a partition with the
# completeness assertion below and the no-separator control — never read alone.
_ra_summary_balances "#619 pristine fixture builder accounts for every index entry it saw" \
  "$_ra_pristine_summary"
_ra_same "#619 pristine fixture builder copied every tracked blob without a copy failure" \
  0 "$(_ra_field "$_ra_pristine_summary" fail_copy)" \
  "copy failures on the live checkout; stderr: $(tr '\n' '|' <"$_ra_pristine_err" 2>/dev/null)"
# `fail_mode`'s sibling pin, and it is NOT redundant with the completeness pair: a mode
# that failed to apply leaves the file on disk, so the oracle — which compares path sets
# — reports neither `extra` nor `missing`, and `_ra_summary_balances` balances happily
# with `fail_mode` equal to the whole index. Without this assertion a `chmod` that is
# absent (rc 127; it is not preflight-guaranteed), EPERM on a shared mount, or a
# filesystem ignoring mode bits yields a pristine image whose helpers are all
# non-executable while every other pristine assertion stays green — and the downstream
# rows then fail with a diagnosis aimed at the generators instead of the fixture.
_ra_same "#619 pristine fixture builder applied every index mode without failure" \
  0 "$(_ra_field "$_ra_pristine_summary" fail_mode)" \
  "mode-application failures on the live checkout; stderr: $(tr '\n' '|' <"$_ra_pristine_err" 2>/dev/null)"
_ra_ok "#619 pristine fixture reproduces every tracked entry the skip arms did not remove" \
  "$([ "$(_ra_field "$RA_PRISTINE_REPORT" missing)" = 0 ] && printf yes)" \
  "tracked entries absent from the image: $RA_PRISTINE_REPORT"
# The paired positive control for the two counts above: without a no-separator check
# an empty image would satisfy `extra=0`, and the directory-shaped-CLAUDE.md
# regression (`${var%/*}` returning the whole string) would pass unnoticed.
_ra_ok "#619 pristine fixture reproduces a no-separator path as a regular file" \
  "$([ -f "$_ra_pristine/CLAUDE.md" ] && [ ! -d "$_ra_pristine/CLAUDE.md" ] && printf yes)" \
  "CLAUDE.md is absent or a directory in the image"
# The builder's own bookkeeping must agree with the independent oracle, so a
# miscounted skip cannot quietly widen the denominator it is subtracted from. Compared
# field by field, so neither summary line's printf order is what the assertion pins.
for _ra_k in skip_missing skip_gitlink skip_symlink; do
  _ra_same_field "#619 fixture builder $_ra_k tally agrees with the independent oracle" \
    "$RA_PRISTINE_REPORT" "$_ra_pristine_summary" "$_ra_k" \
    "builder summary '$_ra_pristine_summary' vs oracle '$RA_PRISTINE_REPORT'"
done
# Builder/oracle AGREEMENT above proves only that the two halves agree about an
# omission — not that none occurred: a newly tracked symlink or submodule is skipped by
# the builder AND excluded from the oracle's denominator, so `missing` stays 0 and every
# completeness assertion stays green while the pristine image is quietly incomplete,
# which is exactly the drift the "complete, never a subset" rule exists to prevent. Pin
# the two structural skip arms to zero so that day turns the desk RED with a named cause
# rather than passing. (`skip_missing` is deliberately NOT pinned: it reports a
# working-tree condition — a locally deleted tracked file — not a property of the
# repository, so pinning it would go RED on a dirty checkout rather than on real drift.)
for _ra_k in skip_gitlink skip_symlink; do
  _ra_same "#619 the live checkout contributes no $_ra_k skip (the pristine image is complete)" \
    0 "$(_ra_field "$_ra_pristine_summary" "$_ra_k")" \
    "a tracked non-blob entered the repository and is silently absent from every fixture; stderr: $(tr '\n' '|' <"$_ra_pristine_err" 2>/dev/null)"
done
# No path under `.claude/worktrees` — the untracked payload the old whole-directory
# builder copied wholesale — may appear in the image.
_ra_ok "#619 pristine fixture carries no .claude/worktrees payload" \
  "$([ ! -d "$_ra_pristine/.claude/worktrees" ] && printf yes)" \
  ".claude/worktrees present in the image"

# ── The helpers' own degraded arms, driven rather than merely reasoned about ──
# Each arm below exists to stop a vacuous pass, so each needs a caller that reaches it:
# without one, deleting the arm is a GREEN mutation and the guarantee is decorative.
# Every drivable degraded arm this module adds has a caller below — the builder's
# `fail_copy` and `fail_mode` channels and both `unestablished` sentinels included.
# NOT drivable here, with the reason recorded rather than silently skipped:
# `_ra_same_field`'s unset-rejection arm, `_ra_summary_balances`' non-numeric arm and
# `_ra_has_file`'s count-unestablished arm all discharge by calling `assert_eq` with a
# failing expectation — driving one registers a real module FAIL, so they are covered by
# reading, not by a caller. Their shared operand `_ra_field` IS driven, immediately below.
_ra_same "#619 _ra_field anchors on the key boundary (a short key cannot match inside a longer one)" \
  7 "$(_ra_field "extra=1 skip_missing=3 missing=7" missing)" \
  "an unanchored expansion would return the skip_missing value"
_ra_same "#619 _ra_field returns the unset sentinel for an absent key (never a silent zero)" \
  unset "$(_ra_field "extra=1 missing=2" total)" "an absent key must not read as a value"
# The oracle's fail-closed sentinel: with an unestablished index or image BOTH sides of
# its set difference are empty, so the honest report is `unestablished`, never a vacuous
# `extra=0 missing=0` from the one artifact whose job is to catch the builder lying.
# The absent-image arm is what is driven here — an absent *src* would raise inside
# `subprocess.run(cwd=...)` rather than return an rc, and a merely-non-repo directory is
# not a reliable fixture (git searches upward, so a temp root nested under a checkout
# would resolve the enclosing repository and succeed).
RA_UNEST_REPORT="$(_ra_image_report "$RA_REPO" "$_ra_tmp_root/no-such-image" 2>/dev/null)"
_ra_same "#619 the oracle reports unestablished (never a vacuous extra=0) when the image cannot be established" \
  unestablished "$(_ra_field "$RA_UNEST_REPORT" extra)" "report: $RA_UNEST_REPORT"
# The builder's matching arm — the bash half of the coupled mirror honoring the same
# rule. Without it a failed enumeration prints `total=0 copied=0 ...`, which
# `_ra_summary_balances` then certifies as balanced (0 == 0+0+...).
_ra_unest_summary="$(_ra_build_image "$_ra_tmp_root/no-such-src" "$_ra_tmp_root/unestimg" 2>/dev/null)"
_ra_same "#619 the fixture builder reports unestablished (never a vacuous total=0) when the index cannot be read" \
  unestablished "$(_ra_field "$_ra_unest_summary" total)" "summary: $_ra_unest_summary"
# The `fail_copy` channel, driven: a regular file sitting where a nested entry's parent
# directory must go makes `mkdir -p` fail, so the entry is counted and breadcrumbed on
# its own channel instead of vanishing into the gap between `total` and `copied`.
_ra_fc="$_ra_tmp_root/fcrepo"
_ra_ok "#619 copy-failure fixture repository seeded" "$(_ra_seed_repo "$_ra_fc" && printf yes)" \
  "git init/config failed; the fail_copy arm would run against a dead repo"
(
  cd "$_ra_fc" || exit 1
  mkdir -p nested
  printf 'blocked\n' > nested/inner.txt
  printf 'fine\n' > ok.txt
  git add -A
  git commit -q -m seed
) >/dev/null 2>&1
_ra_fc_img="$_ra_tmp_root/fcimg"
_ra_fc_err="$_ra_tmp_root/fc.err"
mkdir -p "$_ra_fc_img"
: > "$_ra_fc_img/nested"   # a FILE where the entry's parent directory must be created
_ra_fc_summary="$(_ra_build_image "$_ra_fc" "$_ra_fc_img" 2>"$_ra_fc_err")"
_ra_has_file "#619 fixture builder breadcrumbs a tracked entry it could not copy" \
  "$_ra_fc_err" "FAILED to copy tracked entry nested/inner.txt"
for _ra_k in "fail_copy 1" "copied 1" "total 2"; do
  _ra_kn="${_ra_k%% *}"; _ra_kv="${_ra_k##* }"
  _ra_same "#619 fixture builder counts a copy failure on its own channel ($_ra_kn)" \
    "$_ra_kv" "$(_ra_field "$_ra_fc_summary" "$_ra_kn")" "summary: $_ra_fc_summary"
done
_ra_summary_balances "#619 a copy failure still balances the builder's own accounting" \
  "$_ra_fc_summary"
# The `fail_mode` channel, driven. `chmod` is shadowed by a stub that exits 1, for the
# duration of ONE build only: the assignment and the `hash -r` (bash caches resolved
# command paths, so an already-hashed chmod would bypass the new PATH) both live inside
# the command substitution's subshell, so nothing leaks into the rest of the module.
# A PATH stub — rather than an unwritable directory — is what reproduces the rc-127
# absent-`chmod` host the block's comment claims to cover, and it needs no privilege.
_ra_fm="$_ra_tmp_root/fmrepo"
_ra_ok "#619 mode-failure fixture repository seeded" "$(_ra_seed_repo "$_ra_fm" && printf yes)" \
  "git init/config failed; the fail_mode arm would run against a dead repo"
(
  cd "$_ra_fm" || exit 1
  printf 'x\n' > only.txt
  git add -A
  git commit -q -m seed
) >/dev/null 2>&1
_ra_cmstub="$_ra_tmp_root/chmodstub"
mkdir -p "$_ra_cmstub"
printf '#!/bin/sh\nexit 1\n' > "$_ra_cmstub/chmod"
chmod 755 "$_ra_cmstub/chmod"   # the real chmod, before anything is shadowed
_ra_fm_err="$_ra_tmp_root/fm.err"
_ra_fm_summary="$(PATH="$_ra_cmstub:$PATH"; hash -r 2>/dev/null; _ra_build_image "$_ra_fm" "$_ra_tmp_root/fmimg" 2>"$_ra_fm_err")"
_ra_has_file "#619 fixture builder breadcrumbs an index mode it could not apply" \
  "$_ra_fm_err" "FAILED to set index mode 100644 on only.txt"
# `copied 0` is the load-bearing half: a mode that did not apply must NOT be counted as
# a clean copy, which is the whole reason this channel is separate from `fail_copy`.
for _ra_k in "fail_mode 1" "copied 0" "fail_copy 0" "total 1"; do
  _ra_kn="${_ra_k%% *}"; _ra_kv="${_ra_k##* }"
  _ra_same "#619 fixture builder counts a mode failure on its own channel ($_ra_kn)" \
    "$_ra_kv" "$(_ra_field "$_ra_fm_summary" "$_ra_kn")" "summary: $_ra_fm_summary"
done
_ra_summary_balances "#619 a mode failure still balances the builder's own accounting" \
  "$_ra_fm_summary"
# The stub was scoped to the substitution above; prove it did not leak, or every
# later arm's mode expectations would be silently measuring the stub instead.
_ra_ok "#619 the chmod stub did not leak past the mode-failure build" \
  "$(case "$(command -v chmod)" in *chmodstub*) ;; *) printf yes ;; esac)" \
  "chmod still resolves to the stub after the scoped build"

# The index-state arms are exercised against a REAL git index in a temp repository,
# never a stubbed `git ls-files` — that is the boundary each of these proves.
_ra_ix="$_ra_tmp_root/ixrepo"
_ra_ok "#619 index-state fixture repository seeded" \
  "$(_ra_seed_repo "$_ra_ix" && printf yes)" \
  "git init/config failed; every index-state arm below would run against a dead repo"
# Symlink capability probe (issue #714 review). A `core.symlinks=false` checkout —
# Windows/Git Bash without the symlink privilege, the same host class the
# `core.fileMode false` reproduction below deliberately accommodates — turns `ln -s`
# into a plain file copy, so git would record 100644 and the symlink arm would go RED
# claiming the builder mis-triaged a symlink it was never given. Probe the host once and
# gate only the symlink rows on it: an unsupported host omits `link.md` entirely (so
# `copied` is unchanged at 5) and records a visible host-capability note rather than a
# false failure. The gitlink arm needs no probe — it synthesizes its 160000 entry with
# `update-index --cacheinfo` instead of requiring a real submodule checkout.
_ra_symlink_ok=no
if ln -s TOP.md "$_ra_tmp_root/.ra-symlink-probe" 2>/dev/null &&
   [ -L "$_ra_tmp_root/.ra-symlink-probe" ]; then
  _ra_symlink_ok=yes
fi
rm -f "$_ra_tmp_root/.ra-symlink-probe" 2>/dev/null || :
# NOT a `  NOTE ` emit: that exact shape is reserved for `lib/test/run.sh`'s `skip`
# helper (a meta-assertion REDs the suite on any other producer), and this module is
# sourced below that helper's scope. Announce the gated rows on stderr instead, so an
# unsupported host leaves an auditable trace rather than a silently smaller assertion set.
[ "$_ra_symlink_ok" = yes ] ||
  printf 'regenerate-artifacts: symlink index-entry rows gated out (host-capability: this filesystem/checkout cannot create a symlink, so a 120000 index entry cannot be built)\n' >&2
mkdir -p "$_ra_ix/sub dir"
(
  cd "$_ra_ix" || exit 1
  printf 'top\n' > TOP.md
  printf 'nested\n' > "sub dir/with space.txt"
  # A NEWLINE in a filename is the load-bearing half of the `-z` claim: without -z the
  # space case still works (the path is taken whole after the TAB) but this one splits
  # one index entry into two. The space fixture alone cannot catch that mutation.
  printf 'newline\n' > "$(printf 'new\nline.txt')"
  : > empty.txt
  printf '#!/bin/sh\n' > exec.sh
  chmod 755 exec.sh
  printf 'gone\n' > deleted.txt
  [ "$_ra_symlink_ok" = yes ] && ln -s TOP.md link.md || :
  git add -A
  git commit -q -m seed
  # Tracked-then-deleted WITHOUT `git rm`: the index still lists it, the working tree
  # does not carry it.
  rm -f deleted.txt
  # core.fileMode=false is git's default on Windows: the index keeps 100755 while the
  # on-disk bit is dropped. Reproduce that exact disagreement here.
  git config core.fileMode false
  chmod 644 exec.sh
) >/dev/null 2>&1
_ra_ix_img="$_ra_tmp_root/iximg"
_ra_ix_err="$_ra_tmp_root/ix.err"
_ra_ix_summary="$(_ra_build_image "$_ra_ix" "$_ra_ix_img" 2>"$_ra_ix_err")"

# Each arm's breadcrumb is asserted as its OWN distinct string — that is what stops one
# arm silently covering another.
_ra_has_file "#619 fixture builder breadcrumbs the index entry with no working-tree file" \
  "$_ra_ix_err" "skipping index entry with no working-tree file deleted.txt"
if [ "$_ra_symlink_ok" = yes ]; then
  _ra_has_file "#619 fixture builder breadcrumbs the symlink index entry" \
    "$_ra_ix_err" "skipping symlink index entry link.md"
  _ra_ok "#619 fixture builder omits the skipped symlink entry from the image" \
    "$([ ! -e "$_ra_ix_img/link.md" ] && printf yes)" "the skipped symlink was materialized"
fi
_ra_ok "#619 fixture builder omits the skipped no-working-tree-file entry from the image" \
  "$([ ! -e "$_ra_ix_img/deleted.txt" ] && printf yes)" \
  "a skipped entry was materialized"
_ra_expect_symlink=0
[ "$_ra_symlink_ok" = yes ] && _ra_expect_symlink=1 || :
for _ra_k in "skip_missing 1" "skip_gitlink 0" "skip_symlink $_ra_expect_symlink"; do
  _ra_kn="${_ra_k%% *}"; _ra_kv="${_ra_k##* }"
  _ra_same "#619 fixture builder subtracts $_ra_kn from the denominator by name" \
    "$_ra_kv" "$(_ra_field "$_ra_ix_summary" "$_ra_kn")" "summary: $_ra_ix_summary"
done
RA_IX_REPORT="$(_ra_image_report "$_ra_ix" "$_ra_ix_img")"
_ra_ok "#619 fixture builder skip arms leave no completeness gap" \
  "$([ "$(_ra_field "$RA_IX_REPORT" extra)" = 0 ] && [ "$(_ra_field "$RA_IX_REPORT" missing)" = 0 ] && printf yes)" \
  "$RA_IX_REPORT"
# Positive control for the pair above: `extra=0 missing=0` is also what an EMPTY index
# against an empty image reports, so pin the count of blobs this fixture actually has
# (TOP.md, sub dir/with space.txt, new\nline.txt, empty.txt, exec.sh — deleted.txt and
# link.md are the two skipped arms).
_ra_same "#619 the index-state fixture image is non-empty (completeness pair is live)" \
  5 "$(_ra_field "$_ra_ix_summary" copied)" "summary: $_ra_ix_summary"
_ra_summary_balances "#619 index-state fixture builder accounts for every index entry it saw" \
  "$_ra_ix_summary"
_ra_ok "#619 fixture builder reproduces a path containing a newline (the -z contract)" \
  "$([ -f "$_ra_ix_img/$(printf 'new\nline.txt')" ] && printf yes)" \
  "a newline-bearing tracked path was split or lost — the -z read is not holding"
# Modes come from the index even though the working-tree bit disagrees.
_ra_ok "#619 fixture builder sets modes from the index (100755 stays executable)" \
  "$([ -x "$_ra_ix_img/exec.sh" ] && printf yes)" \
  "exec.sh is not executable in the image; the working-tree bit was inherited"
_ra_ok "#619 fixture builder sets modes from the index (100644 stays non-executable)" \
  "$([ ! -x "$_ra_ix_img/TOP.md" ] && printf yes)" "TOP.md is executable in the image"
# Boundary paths: no directory component, a space in the path, and a zero-byte file.
for _ra_case in "TOP.md" "sub dir/with space.txt" "empty.txt"; do
  _ra_ok "#619 fixture builder reproduces boundary path: $_ra_case" \
    "$([ -f "$_ra_ix_img/$_ra_case" ] && printf yes)" "absent from the image"
done
_ra_ok "#619 fixture builder reproduces a tracked empty file with zero bytes" \
  "$([ -f "$_ra_ix_img/empty.txt" ] && [ ! -s "$_ra_ix_img/empty.txt" ] && printf yes)" \
  "empty.txt is absent or non-empty"
# Gitlink arm: a synthetic 160000 index entry, added with update-index so no real
# submodule checkout is required.
_ra_gl="$_ra_tmp_root/glrepo"
_ra_ok "#619 gitlink fixture repository seeded" "$(_ra_seed_repo "$_ra_gl" && printf yes)" \
  "git init/config failed; the gitlink arm would run against a dead repo"
(
  cd "$_ra_gl" || exit 1
  printf 'x\n' > keep.txt
  git add -A
  git commit -q -m seed
  git update-index --add --cacheinfo 160000,"$(git rev-parse HEAD)",vendored
) >/dev/null 2>&1
_ra_gl_summary="$(_ra_build_image "$_ra_gl" "$_ra_tmp_root/glimg" 2>"$_ra_tmp_root/gl.err")"
_ra_has_file "#619 fixture builder breadcrumbs the gitlink index entry" \
  "$_ra_tmp_root/gl.err" "skipping gitlink index entry vendored"
for _ra_k in "copied 1" "skip_gitlink 1" "skip_missing 0" "skip_symlink 0"; do
  _ra_kn="${_ra_k%% *}"; _ra_kv="${_ra_k##* }"
  _ra_same "#619 fixture builder skips a gitlink without failing the build ($_ra_kn)" \
    "$_ra_kv" "$(_ra_field "$_ra_gl_summary" "$_ra_kn")" "summary: $_ra_gl_summary"
done
# Unmerged index: the same path at stages 1/2/3 contributes exactly once.
_ra_cf="$_ra_tmp_root/cfrepo"
_ra_ok "#619 unmerged-index fixture repository seeded" \
  "$(_ra_seed_repo "$_ra_cf" -b main && printf yes)" \
  "git init/config failed; the unmerged-stage arm would run against a dead repo"
(
  cd "$_ra_cf" || exit 1
  printf 'base\n' > c.txt; git add -A; git commit -q -m base
  git checkout -q -b other
  printf 'other\n' > c.txt; git add -A; git commit -q -m other
  git checkout -q main
  printf 'mine\n' > c.txt; git add -A; git commit -q -m mine
  git merge other
) >/dev/null 2>&1
# PRECONDITION, asserted rather than assumed: `total 1` / `copied 1` is ALSO what a
# clean single-file repo reports, so without proving the index really is unmerged this
# arm would keep passing while exercising no de-duplication at all — a future git that
# auto-resolves, or an inherited rerere, would empty it silently. Count the stage-2/3
# rows `git ls-files -u` reports for the conflicted path (bash builtin arithmetic; no
# `wc`, which is not preflight-guaranteed and must not decide an emitted value).
_ra_cf_unmerged=0
while IFS= read -r _ra_line; do
  [ -n "$_ra_line" ] && _ra_cf_unmerged=$((_ra_cf_unmerged + 1))
done < <(cd "$_ra_cf" && git ls-files -u 2>/dev/null)
_ra_ok "#619 the unmerged-index fixture really has a conflicted path (de-dup arm is live)" \
  "$([ "$_ra_cf_unmerged" -ge 2 ] && printf yes)" \
  "git ls-files -u reported $_ra_cf_unmerged stage rows; the merge did not conflict, so the de-duplication below would be vacuous"
_ra_cf_err="$_ra_tmp_root/cf.err"
_ra_cf_summary="$(_ra_build_image "$_ra_cf" "$_ra_tmp_root/cfimg" 2>"$_ra_cf_err")"
for _ra_k in "total 1" "copied 1"; do
  _ra_kn="${_ra_k%% *}"; _ra_kv="${_ra_k##* }"
  _ra_same "#619 fixture builder de-duplicates unmerged index stages ($_ra_kn)" \
    "$_ra_kv" "$(_ra_field "$_ra_cf_summary" "$_ra_kn")" \
    "expected one entry, got '$_ra_cf_summary'; stderr: $(tr '\n' '|' <"$_ra_cf_err" 2>/dev/null)"
done

# A fixture must be a git repository: coverage_map_guard.py enumerates the tracked
# surface with `git ls-files`. The synthetic origin/main ref keeps the fixture a
# faithful image of a real checkout.
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

# Re-reconcile the cloud-writer closure in a fixture after planting a change that also
# moves a reached asset, so a downstream judgment assertion is attributable to the row
# under test rather than to incidental manifest drift.
_ra_reconcile() {  # <root>
  # rc is CHECKED, not swallowed: if the reconcile step silently fails, the manifest row
  # stays drifted and the downstream assertion becomes attributable to that row instead of
  # the one under test — a vacuous pass wearing a green tick. Surface it as a named failure
  # rather than letting the caller's assertion misreport what it measured.
  if ! ( cd "$1" && python3 lib/test/cloud_writer_contract.py generate >/dev/null 2>&1 ) >/dev/null 2>&1; then
    assert_eq "#619 fixture reconcile succeeded for ${1##*/}" yes \
      "no(cloud-writer generate failed; downstream assertions would be misattributed)"
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
_ra_has() {  # name root substring   (the fixture-root form of _ra_has_file)
  _ra_has_file "$1" "$2/.ra.out" "$3"
}

# The registry's row names, declared ONCE and consumed by both the A1 clean-line loop
# and the A4 --list loop — adding a row must not mean editing two lists.
RA_ROW_NAMES="cloud-writer-manifest capability-profile-literals coverage-map-ratchet"

# ── A1 — clean-tree run: exit 0 with a per-row clean line for every row ──────
# Run against a PRISTINE FIXTURE, never the live checkout. Two reasons, both real:
# (1) the mechanical row WRITES scripts/devflow-cloud-writer-contract.json, so a live
#     run would mutate a tracked file in the developer's tree as a test side effect —
#     invisible on a reconciled tree, a silent regeneration on exactly the drifted tree
#     this helper exists to detect;
# (2) the live tree's cleanliness is a property of whatever branch the suite runs on,
#     not of the helper — a branch legitimately editing a generated artifact's source
#     makes its row emit JUDGMENT, so a live per-row `clean` assertion would go RED for
#     reasons unrelated to the code under test.
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
# Corrupt the checked-in manifest itself so `generate` rewrites it, rather than mutating
# a reached skill *asset* (which would break the closure and yield a closure error
# instead). The asset closure stays intact, so this is manifest drift (the exit-0-with-
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

# ── A3 — a judgment drift in ONE invocation: judgment item, write scope honored ─
RA_A3="$_ra_tmp_root/a3"; _ra_fixture "$RA_A3"
python3 "$RA_CAPMUT" "$RA_A3" profiles-extra-key >/dev/null 2>&1 \
  || assert_eq "#619 A3 planted capability drift applied" yes "no(cap-mutate failed)"
# Byte snapshots of every judgment-gated artifact: the helper must not write ANY of
# them. This is the write-scope guarantee stated as a negative assertion, taken with
# the suppressed input (planted drift) present rather than on a clean tree.
RA_A3_WF="$(cat "$RA_A3/.github/workflows/devflow-runner.yml" "$RA_A3/.github/workflows/devflow.yml" \
            "$RA_A3/.github/workflows/devflow-implement.yml" "$RA_A3/.github/workflows/matcher-probe.yml")"
RA_A3_LOCK="$(cat "$RA_A3/lib/review-profile.tokens")"
RA_A3_COVMAP="$(cat "$RA_A3/lib/test/modules/coverage-map.json")"
_ra_run "$RA_A3"
assert_eq "#619 A3 capability drift exits 1" "1" "$(_ra_rc "$RA_A3")"
_ra_has "#619 A3 one invocation reports the capability judgment item" "$RA_A3" \
  "[capability-profile-literals] JUDGMENT"
_ra_has "#619 A3 the capability item names its governing policy" "$RA_A3" \
  "update lib/review-profile.tokens when the resolved review list widens"
_ra_cmp() {  # name expected root-relative-file
  _ra_same "$1" "$2" "$(cat "$RA_A3/$3")" "$3 was written by a judgment row"
}
RA_A3_WF_NOW="$(cat "$RA_A3/.github/workflows/devflow-runner.yml" "$RA_A3/.github/workflows/devflow.yml" \
                "$RA_A3/.github/workflows/devflow-implement.yml" "$RA_A3/.github/workflows/matcher-probe.yml")"
_ra_same "#619 A3 write scope: the four workflow files are byte-unchanged" \
  "$RA_A3_WF" "$RA_A3_WF_NOW" "a workflow was written by a judgment row"
_ra_cmp "#619 A3 write scope: lib/review-profile.tokens is byte-unchanged" "$RA_A3_LOCK" lib/review-profile.tokens
# The coverage-map ratchet is a judgment row like every other, so its artifact is
# equally in the never-written set — omitting it left one registered judgment row's
# write scope unasserted.
_ra_cmp "#619 A3 write scope: the coverage map is byte-unchanged" "$RA_A3_COVMAP" lib/test/modules/coverage-map.json
_ra_live_unchanged "#619 A3 live manifest byte-unchanged after the capability-drift run"

# ── A4 — --list names every artifact ────────────────────────────────────────
RA_LIST="$(python3 "$RA_HELPER" --list 2>&1)"; RA_LIST_RC=$?
assert_eq "#619 A4 --list exits 0" "0" "$RA_LIST_RC"
for _row in $RA_ROW_NAMES; do
  case "$RA_LIST" in
    *"artifact	$_row	"*) assert_eq "#619 A4 --list names artifact: $_row" yes yes ;;
    *) assert_eq "#619 A4 --list names artifact: $_row" yes "no($_row absent from --list)" ;;
  esac
done

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
# Plant coverage-map drift (an uncovered helper) for the JUDGMENT half, and remove the
# capability generator for the INFRASTRUCTURE half.
printf '# scratch\n' > "$RA_A5P/lib/uncovered-helper-a5p.sh"
( cd "$RA_A5P" && git add -A && git commit -q -m "plant coverage drift" ) >/dev/null 2>&1
_ra_reconcile "$RA_A5P"
rm -f "$RA_A5P/lib/generate-capability-profiles.py"
_ra_run "$RA_A5P"
# Positive control for the precedence claim (guard-class shape 3). The rc assertion
# below passes on the infrastructure condition ALONE — `main()` returns 2 whenever
# `infrastructure` is set, regardless of `forces_one` — so without establishing that a
# judgment item was ALSO present, the arm measures a plain exit-2 run and would stay
# green if the coverage row silently stopped reporting drift for this edit shape. Pin the
# judgment row's own attributed signal first, so precedence is what is actually tested.
_ra_has "#619 A5p the concurrent judgment item is present (precedence positive control)" \
  "$RA_A5P" "[coverage-map-ratchet] JUDGMENT"
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

# ── A5f — default_repo_root anchors its probe to THIS checkout, not the process cwd ──
# The helper's one write target is a tracked file, so a root resolved from an unrelated
# repository would regenerate that repository's manifest. Nothing exercised the anchor:
# every other arm passes --repo-root explicitly, so deleting `cwd=str(here)` left all
# assertions green. Run --list with NO --repo-root from inside an unrelated git repo and
# assert the capability row's conflict-path set — derived from the generator's REGIONS
# under the RESOLVED root — is still DevFlow's own workflow literals.
RA_A5F="$_ra_tmp_root/a5f-unrelated"; mkdir -p "$RA_A5F"
( cd "$RA_A5F" && git init -q . && git config user.email a@b.c && git config user.name t \
  && printf 'x\n' > f.txt && git add -A && git commit -q -m unrelated ) >/dev/null 2>&1
if ( cd "$RA_A5F" && python3 "$RA_HELPER" --list ) > "$RA_A5F/list.out" 2>"$RA_A5F/list.err"; then
  assert_eq "#619 A5f --list succeeds from the unrelated repo" yes yes
else
  assert_eq "#619 A5f --list succeeds from the unrelated repo" yes \
    "no(rc!=0; stderr: $(tr '\n' '|' <"$RA_A5F/list.err"))"
fi
assert_eq "#619 A5f --list from an unrelated repo still resolves THIS checkout's root" "1" \
  "$(devflow_module_pin_count 'conflict-path	capability-profile-literals	.github/workflows/devflow-runner.yml' "$RA_A5F/list.out")"
# Deliberately the bare tab-prefixed path: this catches an unrelated-repo file leaking onto
# ANY emitted line (an artifact, conflict-path, or conflict-sibling line, under any row).
assert_eq "#619 A5f the unrelated repo contributes no emitted path" "0" \
  "$(devflow_module_pin_count '	f.txt' "$RA_A5F/list.out")"
_ra_live_unchanged "#619 A5f live manifest byte-unchanged after the unrelated-repo run"

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

# ── Helper-content contracts (the registration rule and the disclosed non-goals) ─
devflow_module_pin_unique "#619 the helper header carries the registration rule" 'A PR that adds a checked-in generated artifact gated by the suite adds a row to this registry in the same PR.' "$RA_HELPER"
devflow_module_pin_unique "#619 the helper header discloses the excluded hand-maintained inventory" 'DELIBERATELY EXCLUDED as an artifact row, because it is REDUNDANT' "$RA_HELPER"  # structural-pin-ok: surface-presence pin on the helper-header disclosure sentence; removing it breaks no behavioral guarantee (its wording was updated when #765 dropped the prompt-mass inventory from the disclosure)
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

# The live `--list` output (captured in A4) as a FILE, because the harness pin API reads a
# path. Every arm below matches through that API rather than a `case` glob: a `case` pattern
# with two `*` wildcards spans LINES in a multi-line string, so `*"conflict-path	"*"	$1"*`
# would match one row's name against another row's path — a false green on exactly the
# coverage property this block calls load-bearing. devflow_module_pin_count is line-scoped
# and count-returning, so neither that cross-row match nor an unanchored suffix
# (`by-hand` matching `by-hand-ish`) survives it.
RA_C_LIST_F="$_ra_tmp_root/c655-live-list.txt"
printf '%s\n' "$RA_LIST" > "$RA_C_LIST_F"

# One mutation harness: copy the pristine fixture, apply a `sed -E` to the helper inside
# it, re-run `--list` there, and report whether `literal` was present before and after.
# A no-op mutation, a sed error, or a `--list` that fails to run are each their own named
# failure — never a silent "absent after", which would let a broken harness certify a pin
# it never actually exercised.
# ONE fixture root shared by every mutated-helper arm below. Each arm writes its mutated
# helper to a DISTINCT scratch path outside the root and invokes it with --repo-root pointed
# here, so no arm's mutation is visible to another and none of them writes into the root:
# `--list` is read-only (it walks ROWS, reads the capability generator, and prints). Without
# this each arm cost a full `cp -R` of the tracked tree, and this module runs inside the
# slowest step in the repo.
RA_C_SHARED="$_ra_tmp_root/c655-shared"; _ra_fixture "$RA_C_SHARED"
RA_C_MUT=0

_ra_conflict_red_under() {  # name literal mutation
  local name="$1" literal="$2" mutation="$3" mut before after
  RA_C_MUT=$((RA_C_MUT + 1))
  mut="$_ra_tmp_root/c655-mut-$RA_C_MUT.py"
  if ! sed -E "$mutation" "$RA_HELPER" > "$mut" 2>/dev/null; then
    assert_eq "$name" "PASS->FAIL" "mutation-errored"; return 0
  fi
  if cmp -s "$RA_HELPER" "$mut"; then
    assert_eq "$name" "PASS->FAIL" "mutation-noop(the pin would prove nothing)"; return 0
  fi
  # Exactly 1, matching devflow_module_pin_red_under's PASS derivation rather than `-ge 1`:
  # two helpers whose pin names mean different things is the divergence a second copy of a
  # contract always drifts into.
  before="$([ "$(devflow_module_pin_count "$literal" "$RA_C_LIST_F")" = 1 ] \
    && printf 'PASS' || printf 'FAIL')"
  # The mutated run's rc is deliberately IGNORED for the after-state: several mutations
  # here are expected to make `--list` fail closed (a raise), and "the line is gone
  # because the helper refused to emit anything" is exactly as much a RED as "the line is
  # gone because the emit was deleted". A separate arm (the fail-closed pin) asserts the
  # raise path on its own terms.
  python3 "$mut" --list --repo-root "$RA_C_SHARED" >"$mut.out" 2>&1
  after="$([ "$(devflow_module_pin_count "$literal" "$mut.out")" = 1 ] \
    && printf 'PASS' || printf 'FAIL')"
  assert_eq "$name" "PASS->FAIL" "$before->$after"
}

# ── (a) every registered row emits a conflict-class line with an IN-SET value ────
# Derived from RA_ROW_NAMES (the registry's own roster, already coupled to `--list` by
# A4), so a newly-registered row that forgets its class is caught here rather than
# silently omitted from a hand-maintained list.
for _row in $RA_ROW_NAMES; do
  # Sum the three in-set spellings through the line-scoped counter: exactly one must match.
  # A `case` glob would accept an unanchored suffix (`by-hand-ish`) and, with two wildcards,
  # match across LINES — see the RA_C_LIST_F note above.
  _ra_c_inset=0
  for _cls in regenerate reconcile-source by-hand; do
    _ra_c_inset=$((_ra_c_inset + $(devflow_module_pin_count "conflict-class	$_row	$_cls" "$RA_C_LIST_F")))
  done
  assert_eq "#655 --list emits exactly one in-set conflict-class for: $_row" "1" "$_ra_c_inset"
  # One conflict-recipe line per row, non-empty — the recipe the conflict rule follows.
  case "$(sed -n "s/^conflict-recipe	${_row}	//p" "$RA_C_LIST_F")" in
    '') assert_eq "#655 --list emits a non-empty conflict-recipe for: $_row" yes \
          "no(absent or empty)" ;;
    *)  assert_eq "#655 --list emits a non-empty conflict-recipe for: $_row" yes yes ;;
  esac
done
_ra_conflict_red_under "#655 the conflict-class emit is what produces those lines" \
  'conflict-class	coverage-map-ratchet	by-hand' \
  's/^([[:space:]]*)print\(f"conflict-class.*$/\1pass/'

# ── (b) each class ASSIGNMENT pinned; mutation flips one ─────────────────────────
_ra_class_is() {  # row expected-class
  assert_eq "#655 conflict-class assignment: $1 -> $2" "1" \
    "$(devflow_module_pin_count "conflict-class	$1	$2" "$RA_C_LIST_F")"
}
_ra_class_is cloud-writer-manifest       regenerate
_ra_class_is capability-profile-literals reconcile-source
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
# Row-agnostic on purpose (the audit asks "is this artifact covered", not "by which row"),
# so it counts LINES ending in the path via a tab-anchored suffix strip rather than a
# two-wildcard `case` that could pair one row's name with another row's path.
_ra_conflict_path_covered() {  # artifact-path
  local n
  n="$(sed -n "s/^conflict-path	[^	]*	//p" "$RA_C_LIST_F" | grep -cx -F -- "$1")"
  case "$n" in
    ''|*[!0-9]*) assert_eq "#655 conflict-path covers the generated artifact: $1" yes \
                   "no(count unestablished — sed/grep absent)" ;;
    0) assert_eq "#655 conflict-path covers the generated artifact: $1" yes \
         "no($1 is a generated artifact but no conflict-path line names it; a conflict there would take the hand-merge default)" ;;
    *) assert_eq "#655 conflict-path covers the generated artifact: $1" yes yes ;;
  esac
}
_ra_conflict_path_covered scripts/devflow-cloud-writer-contract.json
_ra_conflict_path_covered lib/capability-profiles.json
_ra_conflict_path_covered lib/test/modules/coverage-map.json
# The generated workflow literals, sourced from the generator's own REGIONS rather than
# re-enumerated in the registry. Pinned by their real paths here so a REGIONS rename that
# silently empties the derivation is caught.
_ra_conflict_path_covered .github/workflows/devflow-runner.yml
_ra_conflict_path_covered .github/workflows/devflow.yml
_ra_conflict_path_covered .github/workflows/devflow-implement.yml
_ra_conflict_path_covered .github/workflows/matcher-probe.yml
_ra_conflict_red_under "#655 dropping a row's conflict_paths entry leaves its artifact uncovered" \
  'conflict-path	coverage-map-ratchet	lib/test/modules/coverage-map.json' \
  's/"conflict_paths": \("lib\/test\/modules\/coverage-map.json",\)/"conflict_paths": ()/'
# And the generator-sourced half: emptying REGIONS must NOT silently shrink the set.
# Mutation: drop the bind-loop line that wires the row's conflict_paths_extra callable, so
# the row falls back to its static path alone and every generator-sourced workflow literal
# vanishes from the set.
_ra_conflict_red_under "#655 the workflow literals come from the generator-sourced derivation" \
  'conflict-path	capability-profile-literals	.github/workflows/devflow-runner.yml' \
  's/_row\["conflict_paths_extra"\] = _capability_region_targets/pass/'

# ── (d) each regenerate/reconcile-source recipe names a command the TOOL really has ──
# A substring pin ("the recipe mentions 'generate'") stays green when the subcommand is
# renamed in the tool and the recipe goes dead. So the needle is checked against the
# tool's REAL interface: its `--help` text, or — for the capability generator, which has
# no argparse and rejects `--help` — an actual fixture run of the bare write form.
_ra_recipe_names() {  # row needle
  case "$(sed -n "s/^conflict-recipe	${1}	//p" "$RA_C_LIST_F")" in
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
# The `--help` probes run against the LIVE checkout: argparse prints usage and exits before
# any repo I/O, so they cannot mutate anything and need no copy. The capability generator's
# BARE form is the one arm that writes (it rewrites the five workflow literal regions), so it
# alone gets a private fixture — stated here because it is otherwise invisible why one of
# these three probes is different.
RA_IFACE="$_ra_tmp_root/iface"; _ra_fixture "$RA_IFACE"
assert_eq "#655 recipe interface: cloud-writer names the 'generate' subcommand the tool declares" \
  "yes/yes" \
  "$(_ra_recipe_names cloud-writer-manifest 'cloud_writer_contract.py generate')/$(_ra_tool_has_flag "$RA_REPO" lib/test/cloud_writer_contract.py '*check,generate,verify*')"
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
# The mutation the round-2 finding demands: rename the subcommand IN THE TOOL and confirm
# the interface check goes RED. A substring-only pin stays green here — that is the whole
# point of driving it against the tool's real `--help`. `generate` is an ordinary English
# word likely to appear in argparse prose, so a rename that leaves the word elsewhere in
# the help text would keep a naive check green; renaming the subcommand must still turn it RED.
# A single-file image, not a tree copy: this arm only runs `--help` on that one tool, and
# argparse prints usage before any repo read.
RA_IFACE_MUT="$_ra_tmp_root/iface-mut"; mkdir -p "$RA_IFACE_MUT/lib/test"
sed 's/"generate"/"regen655"/g; s/{check,generate,verify}/{check,regen655,verify}/g' \
  "$RA_REPO/lib/test/cloud_writer_contract.py" > "$RA_IFACE_MUT/lib/test/cloud_writer_contract.py" 2>/dev/null
assert_eq "#655 renaming the 'generate' subcommand in the tool turns the interface check RED" \
  "no" "$(_ra_tool_has_flag "$RA_IFACE_MUT" lib/test/cloud_writer_contract.py '*check,generate,verify*')"

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
# would have no route for. Driven end-to-end: rc must be exactly 2 and the breadcrumb must
# name the offending value, not merely traceback anonymously.
# Both bind-time invariants take the same five steps (mutate the helper, run --list against
# the shared root, require exit 2, then pin the breadcrumb), so they share a helper —
# the same two-call-sites threshold at which this module already extracts one.
# #659 review (Important 3 + 4): this asserted only NON-ZERO, which could not tell exit 2
# (INFRASTRUCTURE — nothing was checked) from exit 1 (a resolvable "action required" item).
# That mattered in both directions. The bind-time arms genuinely exited 1 — the module-level
# raise ran before the `__main__` exit-2 net could catch it — silently contradicting this
# module's own EXIT CONTRACT; and the emit-time duplicate-path arm, which DID reach the net,
# would have stayed green if it ever regressed to 1. The helper now routes the bind-time
# raise to exit 2 (`_validate_registry`), so every arm below is exit 2 and this pins it.
_ra_bind_fails_closed() {  # label mutation needle...
  local label="$1" mutation="$2" mut _rc
  shift 2
  RA_C_MUT=$((RA_C_MUT + 1))
  mut="$_ra_tmp_root/c655-mut-$RA_C_MUT.py"
  sed -E "$mutation" "$RA_HELPER" > "$mut"
  python3 "$mut" --list --repo-root "$RA_C_SHARED" >"$mut.out" 2>&1
  _rc=$?
  assert_eq "#655 $label fails closed (exit 2 INFRASTRUCTURE, never 1)" "2" "$_rc"
  for _needle in "$@"; do
    case "$(devflow_module_pin_count "$_needle" "$mut.out")" in
      ''|*[!0-9]*) assert_eq "#655 $label breadcrumb names: $_needle" yes "no(count unestablished)" ;;
      0) assert_eq "#655 $label breadcrumb names: $_needle" yes "no(absent from the breadcrumb)" ;;
      *) assert_eq "#655 $label breadcrumb names: $_needle" yes yes ;;
    esac
  done
}
_ra_bind_fails_closed "an out-of-set conflict_class" \
  's/"conflict_class": "regenerate"/"conflict_class": "hand-wave"/' \
  "'hand-wave'" "which is outside"
_ra_bind_fails_closed "an empty recipe" \
  's/^        "policy": "add the missing coverage rows.*$/        "policy": "",/' \
  "empty recipe (policy)"

# ── (f2) an underivable region set exits 2 (INFRASTRUCTURE), never 1 ────────────
# `_capability_region_targets` documents that it RAISES rather than returning a partial set, and
# that the top-level net routes the raise to the exit-2 infrastructure state. This arm covers the
# raise that happens DURING a run (the region set is derived under the target root, so it cannot
# be validated at import); the (f) arms above cover the import-time bind validation, which since
# the #659 review reaches the same exit 2 via `_validate_registry`'s routed raise rather than the
# exit 1 a bare module-level raise produced. The distinction is this repo's unchecked-vs-resolvable
# discriminator (the same reason a dozen sibling arms pin "exits 2, never 1"): an exit 1 here
# would tell the agent a conflicted artifact is resolvable when the path set was never derived,
# which is exactly the fail-open the shipped rule's "when --list cannot run" default exists to stop.
_ra_region_fails_infra() {  # label fixture-mutation-command
  local label="$1" dest
  dest="$_ra_tmp_root/c655-regions-$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-')"
  rm -rf "$dest"; _ra_fixture "$dest"
  ( cd "$dest" && eval "$2" ) >/dev/null 2>&1
  python3 "$RA_HELPER" --list --repo-root "$dest" >"$dest/.ra.out" 2>&1
  printf '%s\n' "$?" >"$dest/.ra.rc"
  assert_eq "#655 $label exits 2 (infrastructure), never 1" "2" "$(_ra_rc "$dest")"
  _ra_has "#655 $label is named as an infrastructure failure" "$dest" "INFRASTRUCTURE"
}
# An ABSENT generator: the import itself cannot resolve.
_ra_region_fails_infra "an absent capability generator" \
  "rm -f lib/generate-capability-profiles.py"
# A generator that imports cleanly but declares NO regions: the fail-closed arm inside the
# derivation, distinct from the absent-file arm above (a short list must not read as a clean one).
_ra_region_fails_infra "an empty generator REGIONS list" \
  "sed -E 's/^REGIONS = \\[\$/REGIONS = []  # mutated/' lib/generate-capability-profiles.py > .rg.tmp && mv .rg.tmp lib/generate-capability-profiles.py"

# ── (f3) a row declaring no path source, and a path claimed by TWO rows, fail closed ──
# Both are the same fail-open one level in: without them a misregistered row reaches a consumer
# either with no path at all, or with a path resolving to two contradictory classes the rule has
# no stated tiebreak for. `_ra_bind_fails_closed` drives each end-to-end (non-zero exit plus the
# breadcrumb that names the offence), so neither can regress to a silent listing.
_ra_bind_fails_closed "an empty conflict_paths tuple" \
  's/"conflict_paths": \("lib\/test\/modules\/coverage-map.json",\)/"conflict_paths": ()/' \
  "declares an empty conflict_paths" "at least one conflict path"
# #659 review (Suggestion 2): the arm above mutates the coverage-map row, which declares NO
# `writes`/`record`, so it proves only that an empty tuple raises — not the scenario the guard
# was written for. The fail-open is `()` SHORT-CIRCUITING a fallback that would otherwise have
# resolved a real path: `"conflict_paths" in row` is satisfied by the empty tuple, so the
# writes/record branch is never consulted and the row silently resolves to no path at all.
# Only a row that HAS a working fallback can exercise that, so plant `()` on the cloud-writer
# row, whose `writes` would otherwise supply its artifact path.
_ra_bind_fails_closed "an empty conflict_paths short-circuiting a real writes fallback" \
  's/"writes": MECHANICAL_ARTIFACT,/"writes": MECHANICAL_ARTIFACT, "conflict_paths": (),/' \
  "declares an empty conflict_paths" "at least one conflict path" "cloud-writer-manifest"
# #659 review (Suggestion 1): a path emitted as BOTH a conflict-path and a conflict-sibling
# hands the shipped rule two contradictory classes — the sibling's own fourth field vs the
# owning row's — with no tiebreak, the same fail-open a two-row duplicate is. Point the
# coverage-map row at the capability row's coupled sibling to drive it.
_ra_bind_fails_closed "a path claimed as both a conflict-path and a coupled sibling" \
  's/"conflict_paths": \("lib\/test\/modules\/coverage-map.json",\)/"conflict_paths": ("lib\/review-profile.tokens",)/' \
  "is claimed by both" "coupled by-hand sibling" "exactly one conflict class"
_ra_bind_fails_closed "a row declaring no conflict-path source" \
  's/"conflict_paths": \("lib\/test\/modules\/coverage-map.json",\),//' \
  "declares no conflict-path source" "coverage-map-ratchet"
# Point the coverage-map row at a path the cloud-writer row already owns.
_ra_bind_fails_closed "a conflict path claimed by two rows" \
  's/"conflict_paths": \("lib\/test\/modules\/coverage-map.json",\)/"conflict_paths": ("scripts\/devflow-cloud-writer-contract.json",)/' \
  "is claimed by both" "exactly one conflict class"
# The live registry must actually satisfy the uniqueness invariant the emit enforces — the
# positive control, so the arms above are not the only evidence that duplicates are impossible.
assert_eq "#655 no conflict-path value is claimed by more than one row (live registry)" "" \
  "$(sed -n 's/^conflict-path	[^	]*	//p' "$RA_C_LIST_F" | sort | uniq -d)"

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
RA_C655G_RECIPE="$(sed -n 's/^conflict-recipe	capability-profile-literals	//p' "$RA_C_LIST_F")"
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
# #659 review (Suggestion 5): the replacement sentence points at the rule by PROSE TITLE. The
# heading's existence is pinned above, and the sentence's existence is implied by the retirement
# pin above — but nothing bound the two, so renaming the heading would leave the pointer aiming
# at a section that no longer exists while both pins stayed green. Derive the cross-reference
# needle FROM the heading constant (strip the `## `) rather than re-spelling the title, so the
# two cannot drift: a rename must update the pointer or this goes RED.
assert_eq "#655 implement.md's cross-reference names the rule's actual heading literal" "1" \
  "$(devflow_module_pin_count "under the ${RA_RULE_HEADING#\#\# } section" "$RA_EXT_DIR/implement.md")"

# The generic, repo-agnostic pointer each in-run conflict arm carries. It names no
# DevFlow-internal helper, so it stays correct in the vendored/shipped surfaces.
# The pointer carries its own fail-closed default: without one it states a prohibition the agent
# has no way to evaluate in a repo with no guidance, and falls through to the surrounding
# resolve-it-yourself arm — hand-merging exactly what the sentence forbids.
RA_ARM_POINTER='if you cannot establish whether the conflicted file is generated, stop and mark it needs-human-reconciliation rather than hand-merging'
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
