# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable macOS Bash 3.2 portability-lane module (issue #1277).
#
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first. This module uses assert_eq plus the `_pl_*`
# domain-private helpers defined below; it references no monolith helper and never
# invokes the runner or the full-suite boundary. Modules may not self-skip.
#
# WHAT THIS MODULE COVERS, and the one thing it deliberately does not. Every arm of
# the four lane components is driven here — the totality checker's failure classes,
# the classifier's degraded-input matrix, the supervisor's watchdog, and the
# aggregator gate's conclusion/domain matrix — each against a planted fixture rather
# than the live tree, plus the rendered-workflow boundary assertions that the check
# name, the always-run aggregator and the auto-review dependency edge are actually
# wired. What it does NOT do is run the construct fixtures under Bash 3.2: that
# interpreter exists on the macOS runner and on a developer's Mac, not on the Linux
# host this suite is required to be green on, and a fixture that "passed" by being
# skipped is exactly the laundering issue #456 forbids. The construct fixtures'
# correctness is established by the lane itself; what is established HERE is that the
# machinery selecting, supervising and gating them behaves.
#
# The `trap _pl_cleanup EXIT` below relies on the sourcing contract both callers use
# (module-harness.sh's full-suite boundary and run-module.sh each source this module
# inside a ( ... ) subshell), so the trap fires at subshell exit and cannot clobber the
# runner's own EXIT handling.

PL_REPO="$LIB/.."
PL_TOTALITY="$LIB/test/check-shell-surface-totality.py"
PL_CLASSIFY="$PL_REPO/scripts/classify-portability-risk.py"
PL_SUPERVISOR="$PL_REPO/scripts/run-bash32-fixtures.py"
PL_GATE="$LIB/test/gate-portability-result.sh"
PL_REGISTRY="$PL_REPO/lib/shell-surface-registry.json"
PL_FIXTURE_DIR="$LIB/test/fixtures/bash32"
PL_CI="$PL_REPO/.github/workflows/ci.yml"

# The harness's owned-directory allocator rather than a bare `mktemp -d`: it snapshots
# the template namespace and refuses a candidate it did not create, so a colliding or
# pre-planted directory is a loud failure instead of a fixture tree this module then
# deletes on the way out.
_pl_tmp_root="$(devflow_module_allocate_owned_directory \
  "${TMPDIR:-/tmp}/devflow-portability-lane.XXXXXX")" || {
  printf 'could not allocate portability-lane fixture\n' >&2
  return 1
}
_pl_cleanup() {
  rm -rf "$_pl_tmp_root"
}
trap _pl_cleanup EXIT

# ── Fixture builders ────────────────────────────────────────────────────────────
#
# A fixture repository is a real git repo with a real index, because the totality
# checker's whole point is that it derives its population from `git ls-files` rather
# than from the registry. A fixture that handed it a path list would test the
# reconciliation while stubbing out the derivation it exists to perform.

# _pl_new_repo <name> — create a fixture repo, print its path.
_pl_new_repo() {
  local r="$_pl_tmp_root/$1"
  mkdir -p "$r/lib/test/fixtures" "$r/scripts"
  git -C "$r" init -q 2>/dev/null || git init -q "$r"
  git -C "$r" config user.email devflow@example.invalid
  git -C "$r" config user.name devflow
  printf '%s' "$r"
}

# _pl_track <repo> <path> — write a trivial shell file and add it to the index.
_pl_track() {
  mkdir -p "$(dirname "$1/$2")"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/$2"
  git -C "$1" add -- "$2"
}

# _pl_registry <repo> <json> — write the registry the checker will read.
_pl_registry() {
  mkdir -p "$1/lib"
  printf '%s\n' "$2" > "$1/lib/shell-surface-registry.json"
}

# _pl_totality <repo> — run the checker, print `rc=<n>|<first stdout line>`.
_pl_totality() {
  local out rc
  out="$(python3 "$PL_TOTALITY" --root "$1" 2>/dev/null)"
  rc=$?
  printf 'rc=%s|%s' "$rc" "${out%%$'\n'*}"
}

# _pl_verdict <repo> — print only the FAIL class token (the text before the colon
# after `FAIL: `), so an assertion pins the class rather than the offender list.
_pl_verdict() {
  local line
  line="$(_pl_totality "$1")"
  case "$line" in
    *"|FAIL: "*)
      line="${line#*|FAIL: }"
      printf '%s' "${line%%:*}"
      ;;
    *"|OK"*) printf 'OK' ;;
    *) printf 'UNEXPECTED(%s)' "$line" ;;
  esac
}

# ── 1. Totality checker: the clean control, then one failure class per fixture ──
#
# RED-first by construction: each fixture starts from the clean control below and
# mutates exactly one thing, so an assertion that stopped discriminating would show
# up as the control and the mutant agreeing.

_pl_clean="$(_pl_new_repo totality-clean)"
_pl_track "$_pl_clean" scripts/alpha.sh
_pl_track "$_pl_clean" scripts/beta.sh
_pl_registry "$_pl_clean" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": ["scripts/beta.sh"], "fixture_command": "x", "owning_test_module": "portability-lane"},
    "scripts/beta.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": [], "fixture_command": "x", "owning_test_module": "portability-lane"}
  }
}'
assert_eq "#1277 totality: a registry that classifies every tracked shell file passes" \
  "OK" "$(_pl_verdict "$_pl_clean")"

# The clean control's OK line reports the population it actually reconciled, so a
# checker that silently audited nothing cannot present as a clean pass.
assert_eq "#1277 totality: the clean verdict reports the reconciled population" \
  "rc=0|OK: 2 classified (2 portable, 0 excluded); population totals" \
  "$(_pl_totality "$_pl_clean")"

_pl_unclassified="$(_pl_new_repo totality-unclassified)"
_pl_track "$_pl_unclassified" scripts/alpha.sh
_pl_track "$_pl_unclassified" scripts/orphan.sh
_pl_registry "$_pl_unclassified" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": [], "fixture_command": "x", "owning_test_module": "portability-lane"}
  }
}'
assert_eq "#1277 totality: a tracked shell file the registry does not classify fails" \
  "unclassified" "$(_pl_verdict "$_pl_unclassified")"

_pl_missing="$(_pl_new_repo totality-missing)"
_pl_track "$_pl_missing" scripts/alpha.sh
_pl_registry "$_pl_missing" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": [], "fixture_command": "x", "owning_test_module": "portability-lane"},
    "scripts/deleted.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": [], "fixture_command": "x", "owning_test_module": "portability-lane"}
  }
}'
assert_eq "#1277 totality: a registry key naming an untracked path fails" \
  "missing-tracked" "$(_pl_verdict "$_pl_missing")"

_pl_dup="$(_pl_new_repo totality-duplicate)"
_pl_track "$_pl_dup" scripts/alpha.sh
# A duplicate key survives only in the SOURCE TEXT — json.loads keeps the last one —
# so this fixture is what proves the checker reads the text rather than the parse.
_pl_registry "$_pl_dup" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": [], "fixture_command": "x", "owning_test_module": "portability-lane"},
    "scripts/alpha.sh": {"state": "excluded", "min_bash": "4.0", "reason": "shadowing entry"}
  }
}'
assert_eq "#1277 totality: the same path declared twice fails even though JSON parses" \
  "duplicate" "$(_pl_verdict "$_pl_dup")"

_pl_state="$(_pl_new_repo totality-state)"
_pl_track "$_pl_state" scripts/alpha.sh
_pl_registry "$_pl_state" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "probably-fine", "min_bash": "3.2"}
  }
}'
assert_eq "#1277 totality: a state outside the closed set fails" \
  "unknown-state" "$(_pl_verdict "$_pl_state")"

_pl_stale="$(_pl_new_repo totality-stale)"
_pl_track "$_pl_stale" scripts/alpha.sh
_pl_track "$_pl_stale" scripts/harness.sh
_pl_registry "$_pl_stale" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": ["scripts/harness.sh"], "fixture_command": "x", "owning_test_module": "portability-lane"},
    "scripts/harness.sh": {"state": "excluded", "min_bash": "4.3", "reason": "Bash-4 worker pool"}
  }
}'
assert_eq "#1277 totality: a portable entry sourcing excluded Bash-4 infrastructure fails" \
  "stale-dependency" "$(_pl_verdict "$_pl_stale")"

_pl_unresolved="$(_pl_new_repo totality-unresolved)"
_pl_track "$_pl_unresolved" scripts/alpha.sh
_pl_registry "$_pl_unresolved" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": ["scripts/gone.sh"], "fixture_command": "x", "owning_test_module": "portability-lane"}
  }
}'
assert_eq "#1277 totality: a closure naming an unclassified path fails" \
  "stale-dependency" "$(_pl_verdict "$_pl_unresolved")"

_pl_glob="$(_pl_new_repo totality-glob)"
_pl_track "$_pl_glob" scripts/alpha.sh
_pl_registry "$_pl_glob" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": [], "fixture_command": "x", "owning_test_module": "portability-lane"},
    "lib/test/modules/*.sh": {"state": "excluded", "min_bash": "4.3", "reason": "Bash-4 infrastructure"}
  }
}'
assert_eq "#1277 totality: an excluded Bash-4 pattern key fails rather than swallowing future files" \
  "glob-leakage" "$(_pl_verdict "$_pl_glob")"

_pl_reason="$(_pl_new_repo totality-reason)"
_pl_track "$_pl_reason" scripts/alpha.sh
_pl_registry "$_pl_reason" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "excluded", "min_bash": "4.0", "reason": "   "}
  }
}'
assert_eq "#1277 totality: an exclusion with an empty reason fails" \
  "schema" "$(_pl_verdict "$_pl_reason")"

_pl_field="$(_pl_new_repo totality-field)"
_pl_track "$_pl_field" scripts/alpha.sh
_pl_registry "$_pl_field" '{
  "schema_version": 1,
  "entries": {
    "scripts/alpha.sh": {"state": "portable", "min_bash": "3.2", "shared_library_closure": []}
  }
}'
assert_eq "#1277 totality: a portable entry missing its fixture command fails" \
  "schema" "$(_pl_verdict "$_pl_field")"

_pl_version="$(_pl_new_repo totality-version)"
_pl_track "$_pl_version" scripts/alpha.sh
_pl_registry "$_pl_version" '{"schema_version": 99, "entries": {}}'
assert_eq "#1277 totality: an unsupported schema_version fails closed" \
  "unsupported schema_version 99 (this checker understands 1)" "$(_pl_verdict "$_pl_version")"

_pl_broken="$(_pl_new_repo totality-broken)"
_pl_track "$_pl_broken" scripts/alpha.sh
_pl_registry "$_pl_broken" '{ this is not json'
assert_eq "#1277 totality: an unparseable registry fails closed rather than reporting coverage" \
  "OK" "$(case "$(_pl_verdict "$_pl_broken")" in "the registry is not valid JSON"*) printf OK ;; *) printf 'UNEXPECTED' ;; esac)"

# ── 2. The live registry is total, and its exclusions are all reasoned ──────────

assert_eq "#1277 the live shell-surface registry reconciles against the tracked tree" \
  "rc=0" "$(_pl_totality "$PL_REPO" | { IFS= read -r l; printf '%s' "${l%%|*}"; })"

assert_eq "#1277 every live exclusion carries a non-empty reason and a Bash-4-or-later floor" \
  "clean" "$(python3 - "$PL_REGISTRY" <<'PL_REASONS'
import json, sys
entries = json.load(open(sys.argv[1]))["entries"]
bad = [p for p, r in entries.items()
       if r["state"] == "excluded"
       and (not str(r.get("reason", "")).strip() or r.get("min_bash", "0") < "4")]
print("clean" if not bad else "offenders: " + ", ".join(sorted(bad)))
PL_REASONS
)"

# ── 3. Classifier: the degraded-input matrix ────────────────────────────────────
#
# Each row stubs `gh` through DEVFLOW_GH, which is the documented override the shared
# reader honours, so the classifier's real API path runs against a controlled
# response rather than being bypassed.

# _pl_gh_stub <name> <body-script> — write an executable gh stub, print its path.
_pl_gh_stub() {
  local p="$_pl_tmp_root/gh-$1"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$p"
  chmod +x "$p"
  printf '%s' "$p"
}

# _pl_classify <gh-stub> <args...> — print `<execution>|<established>|<reason>|<n selected>`.
_pl_classify() {
  local stub="$1"; shift
  DEVFLOW_GH="$stub" python3 "$PL_CLASSIFY" --registry "$PL_REGISTRY" "$@" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s|%d" % (d["execution"], d["established"], d["reason"], len(d["selected"])))'
}

_pl_portable_count="$(python3 "$PL_TOTALITY" --root "$PL_REPO" --list-portable 2>/dev/null | { n=0; while IFS= read -r _; do n=$((n + 1)); done; printf '%s' "$n"; })"

# A non-PR event has no files endpoint to read, so this is a DECIDED conservative
# outcome (established=True) rather than a degradation.
assert_eq "#1277 classifier: a non-PR event selects the complete portable population" \
  "conservative|True|non-pr-event|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub noop 'exit 1')" --event-name push)"

# rc != 0 on the metadata read is unestablished, NOT an empty changed-file set.
assert_eq "#1277 classifier: a failed API read is unestablished, never an empty change set" \
  "conservative|False|unestablished|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub fail 'exit 1')" --event-name pull_request --pr 7 --head-sha abc)"

# rc 0 with an unparseable body is the other unestablished arm — a truncated response
# or an HTML error page served with a success status.
assert_eq "#1277 classifier: an unparseable body with rc 0 is unestablished" \
  "conservative|False|unestablished|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub garbage 'printf "<html>not json</html>"')" --event-name pull_request --pr 7 --head-sha abc)"

_pl_ok_meta='if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 1, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"scripts/alpha.sh\", \"status\": \"modified\"}]"; fi'

# Evidence bound to a head the PR has moved past must not narrow anything.
assert_eq "#1277 classifier: evidence bound to a superseded head is unestablished" \
  "conservative|False|unestablished|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub stale "$_pl_ok_meta")" --repo o/r --event-name pull_request --pr 7 --head-sha SUPERSEDED)"

# Pagination that returns fewer distinct files than the PR reports is truncated.
assert_eq "#1277 classifier: a distinct-file tally below changed_files is truncated" \
  "conservative|False|unestablished|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub truncated 'if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 9, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"scripts/alpha.sh\", \"status\": \"modified\"}]"; fi')" \
    --repo o/r --event-name pull_request --pr 7 --head-sha abc)"

# One filename returned twice with disagreeing statuses is conflicting input, not
# something to reconcile by picking one.
assert_eq "#1277 classifier: a filename returned twice with conflicting statuses is unestablished" \
  "conservative|False|unestablished|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub conflict 'if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 1, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"a.sh\", \"status\": \"modified\"}, {\"filename\": \"a.sh\", \"status\": \"removed\"}]"; fi')" \
    --repo o/r --event-name pull_request --pr 7 --head-sha abc)"

# The established path: a change touching one unrelated non-shell file selects nothing.
assert_eq "#1277 classifier: an established population touching no portable surface selects none" \
  "selective|True|changed-file-population-established|0" \
  "$(_pl_classify "$(_pl_gh_stub clean 'if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 1, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"README.md\", \"status\": \"modified\"}]"; fi')" \
    --repo o/r --event-name pull_request --pr 7 --head-sha abc)"

# The UNDER-selection direction, which the zero-selection row above cannot reach: an
# established population touching a genuinely portable surface must return that exact
# subset. Over-selection only wastes runner minutes; under-selection silently ships an
# unverified incompatibility, so a regression that dropped a legitimately-changed file
# has to be visible here.
#
# The probe path is DERIVED, never transcribed: a portable registry entry that is not a
# closure member and that the classifier's own `SELECT_ALL_PATHS`/`SELECT_ALL_PREFIXES`
# do not widen — read out of the classifier module rather than copied, so a widened
# select-all set cannot leave this row silently asserting the wrong branch.
_pl_leaf_surface="$(python3 - "$PL_REPO" "$PL_REGISTRY" <<'PL_LEAF'
import importlib.util, json, sys
from pathlib import Path
root, registry = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("cls", root / "scripts/classify-portability-risk.py")
cls = importlib.util.module_from_spec(spec); spec.loader.exec_module(cls)
entries = json.loads(registry.read_text(encoding="utf-8"))["entries"]
closure = {m for v in entries.values() for m in (v.get("shared_library_closure") or [])}
for path in sorted(p for p, v in entries.items() if v.get("state") == "portable"):
    if path in closure or path in cls.SELECT_ALL_PATHS or path.startswith(cls.SELECT_ALL_PREFIXES):
        continue
    print(path)
    break
PL_LEAF
)"
# An empty probe path would make the row below assert `selective|...|0` and pass while
# checking nothing, so the derivation's own success is asserted first.
assert_eq "#1277 classifier: the selective probe path derives a real leaf portable surface" \
  "yes" "$([ -n "$_pl_leaf_surface" ] && printf 'yes' || printf 'no')"

assert_eq "#1277 classifier: an established population touching one portable surface selects exactly that surface" \
  "selective|True|changed-file-population-established|$_pl_leaf_surface" \
  "$(DEVFLOW_GH="$(_pl_gh_stub leaf 'if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 1, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"%s\", \"status\": \"modified\"}]" "$PL_LEAF_SURFACE"; fi')" \
      PL_LEAF_SURFACE="$_pl_leaf_surface" python3 "$PL_CLASSIFY" --registry "$PL_REGISTRY" \
      --repo o/r --event-name pull_request --pr 7 --head-sha abc 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s|%s" % (d["execution"], d["established"], d["reason"], ",".join(d["selected"])))')"

# Touching the registry re-decides what portable MEANS, so a subset would prove
# nothing about the surface the old registry described.
assert_eq "#1277 classifier: touching the registry selects the complete portable population" \
  "conservative|True|selection-machinery-changed|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub machinery 'if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 1, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"lib/shell-surface-registry.json\", \"status\": \"modified\"}]"; fi')" \
    --repo o/r --event-name pull_request --pr 7 --head-sha abc)"

# A shell file the registry has never classified is exactly the population the
# totality checker would reject, so the lane runs everything rather than guessing.
assert_eq "#1277 classifier: an unclassified shell surface selects the complete portable population" \
  "conservative|True|unclassified-shell-surface-changed|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub newshell 'if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 1, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"scripts/brand-new.sh\", \"status\": \"added\"}]"; fi')" \
    --repo o/r --event-name pull_request --pr 7 --head-sha abc)"

# A file other entries source reaches further than itself.
assert_eq "#1277 classifier: touching a shared dependency selects the complete portable population" \
  "conservative|True|shared-dependency-changed|$_pl_portable_count" \
  "$(_pl_classify "$(_pl_gh_stub shared 'if [ "$2" = "repos/o/r/pulls/7" ]; then printf "{\"changed_files\": 1, \"head\": {\"sha\": \"abc\"}}"; else printf "[{\"filename\": \"lib/resolve-bin.sh\", \"status\": \"modified\"}]"; fi')" \
    --repo o/r --event-name pull_request --pr 7 --head-sha abc)"

# The registry itself is what makes even the conservative population knowable, so an
# unreadable one is a refusal to decide — never a silently empty selection.
assert_eq "#1277 classifier: an unreadable registry refuses to decide rather than selecting none" \
  "2" "$(python3 "$PL_CLASSIFY" --registry "$_pl_tmp_root/absent-registry.json" --event-name push >/dev/null 2>&1; printf '%s' "$?")"

# ── 4. Supervisor: watchdog, interpreter precondition, not_applicable ───────────

# _pl_supervise <args...> — print `rc=<n>|<DOMAIN_RESULT token>`.
_pl_supervise() {
  local out rc domain
  out="$(python3 "$PL_SUPERVISOR" "$@" 2>/dev/null)"
  rc=$?
  domain=""
  while IFS= read -r line; do
    case "$line" in "DOMAIN_RESULT: "*) domain="${line#DOMAIN_RESULT: }" ;; esac
  done <<PL_SUP_OUT
$out
PL_SUP_OUT
  printf 'rc=%s|%s' "$rc" "$domain"
}

# A fixture that outlives its deadline AND leaves a background child behind: the
# child is what proves the watchdog reaches the whole process GROUP. A direct-child
# kill would leave it holding the pipe open and the supervisor would hang here.
_pl_hang_dir="$_pl_tmp_root/hang"
mkdir -p "$_pl_hang_dir"
printf '#!/usr/bin/env bash\nsleep 60 &\nsleep 60\n' > "$_pl_hang_dir/hang.sh"
chmod +x "$_pl_hang_dir/hang.sh"
printf 'hang\thang.sh\ta fixture that outlives its deadline\t1\n' > "$_pl_hang_dir/manifest.tsv"
cp "$PL_FIXTURE_DIR/parse-under-bash32.sh" "$_pl_hang_dir/parse-under-bash32.sh"

_pl_watchdog="$(_pl_supervise --root "$PL_REPO" --bash "$(command -v bash)" \
  --manifest "$_pl_hang_dir/manifest.tsv" --registry "$PL_REGISTRY" \
  --result-file "$_pl_tmp_root/hang-result.txt")"
# The interpreter precondition fires first on a non-3.2 host, which is the correct
# and expected outcome on this Linux/brew-bash suite — either way the domain result
# is `fail`, never a pass, and that is the property being asserted.
assert_eq "#1277 supervisor: a hung fixture or a wrong interpreter both yield domain fail" \
  "rc=1|fail" "$_pl_watchdog"

assert_eq "#1277 supervisor: the persisted result leads with the DOMAIN_RESULT line the gate reads" \
  "DOMAIN_RESULT: fail" "$(IFS= read -r l < "$_pl_tmp_root/hang-result.txt"; printf '%s' "$l")"

# A wrong interpreter must stop the lane BEFORE any fixture runs: a corpus green
# under Bash 5 would report a verified surface it never exercised.
assert_eq "#1277 supervisor: a non-3.2 interpreter fails before any fixture runs" \
  "0" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --bash "$(command -v bash)" \
      --registry "$PL_REGISTRY" --result-file "$_pl_tmp_root/wrong.txt" 2>/dev/null \
      | { n=0; while IFS= read -r l; do case "$l" in "DOMAIN_RESULT: "*) : ;; *) n=$((n + 1)) ;; esac; done; printf '%s' "$n"; })"

# not_applicable is reachable ONLY from a fully-established empty selection, and it
# is decided before the interpreter probe — a head with no macOS-relevant change is
# not gated on the runner's bash identity.
printf '{"schema_version": 1, "execution": "selective", "established": true, "selected": []}\n' \
  > "$_pl_tmp_root/empty-established.json"
assert_eq "#1277 supervisor: an established empty selection is not_applicable" \
  "rc=0|not_applicable" \
  "$(_pl_supervise --root "$PL_REPO" --bash /nonexistent/bash --registry "$PL_REGISTRY" \
      --classification "$_pl_tmp_root/empty-established.json")"

# The mirror case: an UNestablished classification never reaches not_applicable, even
# with an empty list, because "we could not look" is not "there was nothing". It is a
# REFUSAL rather than a lane result — running the construct fixtures over zero
# repository surface and reporting `pass` is exactly the clean-lane-over-nothing the
# supervisor exists to prevent.
printf '{"schema_version": 1, "execution": "conservative", "established": false, "selected": []}\n' \
  > "$_pl_tmp_root/empty-unestablished.json"
assert_eq "#1277 supervisor: an unestablished empty selection is refused, never a clean lane over nothing" \
  "2" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --bash /nonexistent/bash --registry "$PL_REGISTRY" \
      --classification "$_pl_tmp_root/empty-unestablished.json" >/dev/null 2>&1; printf '%s' "$?")"

# The same refusal for an ESTABLISHED but conservative empty selection: a conservative
# decision that selected nothing is a contradiction, not a not_applicable.
printf '{"schema_version": 1, "execution": "conservative", "established": true, "selected": []}\n' \
  > "$_pl_tmp_root/empty-conservative.json"
assert_eq "#1277 supervisor: an established CONSERVATIVE empty selection is refused too" \
  "2" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --bash /nonexistent/bash --registry "$PL_REGISTRY" \
      --classification "$_pl_tmp_root/empty-conservative.json" >/dev/null 2>&1; printf '%s' "$?")"

# `selected` is validated, never coerced: list("pass") would otherwise become the four
# one-character "surfaces" p, a, s, s.
printf '{"schema_version": 1, "execution": "selective", "established": true, "selected": "pass"}\n' \
  > "$_pl_tmp_root/selected-not-a-list.json"
assert_eq "#1277 supervisor: a non-list \`selected\` is refused rather than coerced into characters" \
  "2" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --bash /nonexistent/bash --registry "$PL_REGISTRY" \
      --classification "$_pl_tmp_root/selected-not-a-list.json" >/dev/null 2>&1; printf '%s' "$?")"

# A classifier result from an unrecognised schema is unusable, not a default.
printf '{"schema_version": 99, "execution": "selective", "established": true, "selected": []}\n' \
  > "$_pl_tmp_root/bad-schema.json"
assert_eq "#1277 supervisor: an unrecognised classifier schema_version is refused" \
  "2" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --bash /nonexistent/bash --registry "$PL_REGISTRY" \
      --classification "$_pl_tmp_root/bad-schema.json" >/dev/null 2>&1; printf '%s' "$?")"

# Failure PROPAGATION, on its own: a fixture that exits non-zero must reach the domain
# result. This is the arm a mutant that swallowed a fixture's status would survive —
# the watchdog arm above cannot catch it, because a watchdog expiry takes a different
# code path from an ordinary non-zero exit.
_pl_redfx_dir="$_pl_tmp_root/red-fixture"
mkdir -p "$_pl_redfx_dir"
printf '#!/usr/bin/env bash\necho "deliberately failing fixture" >&2\nexit 1\n' > "$_pl_redfx_dir/red.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_pl_redfx_dir/green.sh"
chmod +x "$_pl_redfx_dir/red.sh" "$_pl_redfx_dir/green.sh"
cp "$PL_FIXTURE_DIR/parse-under-bash32.sh" "$_pl_redfx_dir/parse-under-bash32.sh"
printf '{"schema_version": 1, "execution": "conservative", "established": false, "selected": ["lib/preflight.sh"]}\n' \
  > "$_pl_tmp_root/one-surface.json"

printf 'green\tgreen.sh\ta fixture that passes\t30\n' > "$_pl_redfx_dir/manifest.tsv"
_pl_green_only="$(_pl_supervise --root "$PL_REPO" --bash "$(command -v bash)" \
  --manifest "$_pl_redfx_dir/manifest.tsv" --classification "$_pl_tmp_root/one-surface.json")"

printf 'green\tgreen.sh\ta fixture that passes\t30\nred\tred.sh\ta fixture that fails\t30\n' \
  > "$_pl_redfx_dir/manifest.tsv"
_pl_with_red="$(_pl_supervise --root "$PL_REPO" --bash "$(command -v bash)" \
  --manifest "$_pl_redfx_dir/manifest.tsv" --classification "$_pl_tmp_root/one-surface.json")"

# Both runs use a non-3.2 interpreter, so both stop at the precondition and read `fail`.
# That makes the pair a CONTROL rather than a discriminator on this host — the two must
# agree here, and the discriminating run happens on the macOS lane itself. Asserting
# them separately is what keeps a reader from mistaking the control for the proof.
assert_eq "#1277 supervisor: a green-only corpus under a non-3.2 interpreter still fails at the precondition (control)" \
  "rc=1|fail" "$_pl_green_only"
assert_eq "#1277 supervisor: adding a deliberately failing fixture cannot make the lane report anything but fail" \
  "rc=1|fail" "$_pl_with_red"

# The propagation itself, isolated from the interpreter precondition: run the failing
# fixture through the supervisor's own launcher and assert a non-zero child status maps
# to the `fail` outcome rather than being swallowed.
assert_eq "#1277 supervisor: a fixture's non-zero exit maps to the fail outcome, not a swallowed status" \
  "fail 1" "$(python3 - "$PL_REPO" "$(command -v bash)" "$_pl_redfx_dir/red.sh" <<'PL_PROPAGATE'
import importlib.util, sys
from pathlib import Path
root, bash, fixture = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("sup", root / "scripts/run-bash32-fixtures.py")
sup = importlib.util.module_from_spec(spec); spec.loader.exec_module(sup)
launcher = sup._load_signal_launcher(root)
outcome, status, _duration, _output = sup.run_supervised([bash, str(fixture)], 30, launcher)
print(outcome, status)
PL_PROPAGATE
)"

# The PASS arm, isolated the same way. Every supervisor path reachable end-to-end on
# this Linux host terminates at the interpreter precondition, `not_applicable` or a
# refusal, so the zero-exit -> `pass` mapping runs only on the advisory macOS producer;
# driving `run_supervised` directly gives it host-independent coverage. Paired with the
# red-fixture row below it, this is the discriminating pair the end-to-end control
# cannot be.
assert_eq "#1277 supervisor: a fixture that exits zero maps to the pass outcome with status 0" \
  "pass 0" "$(python3 - "$PL_REPO" "$(command -v bash)" "$_pl_redfx_dir/green.sh" <<'PL_PASS'
import importlib.util, sys
from pathlib import Path
root, bash, fixture = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("sup", root / "scripts/run-bash32-fixtures.py")
sup = importlib.util.module_from_spec(spec); spec.loader.exec_module(sup)
launcher = sup._load_signal_launcher(root)
outcome, status, _duration, _output = sup.run_supervised([bash, str(fixture)], 30, launcher)
print(outcome, status)
PL_PASS
)"

# The WATCHDOG arm, isolated from the interpreter precondition the same way. The
# end-to-end hang case above stops at the precondition on any non-3.2 host, so both of
# its arms read `rc=1|fail` and it cannot discriminate; this drives `run_supervised`
# directly so the expiry path runs on every host. The fixture backgrounds a child that
# records its pid and outlives the deadline — the pid is what proves the kill reached
# the process GROUP rather than the direct child.
_pl_wd_dir="$_pl_tmp_root/watchdog"
mkdir -p "$_pl_wd_dir"
# `$!` rather than `$$`/`$BASHPID`: `$$` inside a subshell reports the PARENT shell,
# and `BASHPID` postdates Bash 3.2 — this lane's whole point is 3.2 portability.
printf '#!/usr/bin/env bash\nsleep 60 &\necho $! > "%s"\nsleep 60\n' \
  "$_pl_wd_dir/child.pid" > "$_pl_wd_dir/hang.sh"
chmod +x "$_pl_wd_dir/hang.sh"
assert_eq "#1277 supervisor: a fixture that outlives its deadline is a watchdog_expiry with no status, and its backgrounded child is reaped with the group" \
  "watchdog_expiry None child-reaped" "$(python3 - "$PL_REPO" "$(command -v bash)" "$_pl_wd_dir/hang.sh" "$_pl_wd_dir/child.pid" <<'PL_WATCHDOG'
import importlib.util, os, sys, time
from pathlib import Path
root, bash, fixture, pidfile = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
spec = importlib.util.spec_from_file_location("sup", root / "scripts/run-bash32-fixtures.py")
sup = importlib.util.module_from_spec(spec); spec.loader.exec_module(sup)
launcher = sup._load_signal_launcher(root)
outcome, status, duration, _output = sup.run_supervised([bash, str(fixture)], 1, launcher)
# The pid file is written by the backgrounded child before it sleeps. An absent or
# unreadable one is reported as its own token rather than silently passing: a probe
# that never found a child to reap proves nothing about the group kill.
try:
    child_pid = int(pidfile.read_text().strip())
except (OSError, ValueError):
    child_pid = None
if child_pid is None:
    reaped = "child-pid-unestablished"
else:
    reaped = "child-survived"
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(child_pid, 0)
        except (ProcessLookupError, PermissionError):
            reaped = "child-reaped"
            break
        time.sleep(0.05)
print(outcome, status, reaped)
PL_WATCHDOG
)"

assert_eq "#1277 supervisor: an unusable classifier result refuses to run rather than verifying nothing" \
  "2" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --registry "$PL_REGISTRY" \
      --classification "$_pl_tmp_root/no-such-classification.json" >/dev/null 2>&1; printf '%s' "$?")"

printf 'bad-row-with-two-fields\tonly-two\n' > "$_pl_tmp_root/bad-manifest.tsv"
assert_eq "#1277 supervisor: a malformed manifest row refuses to run" \
  "2" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --registry "$PL_REGISTRY" \
      --manifest "$_pl_tmp_root/bad-manifest.tsv" >/dev/null 2>&1; printf '%s' "$?")"

printf '# only a comment\n' > "$_pl_tmp_root/empty-manifest.tsv"
assert_eq "#1277 supervisor: an empty manifest refuses rather than reporting a clean empty corpus" \
  "2" "$(python3 "$PL_SUPERVISOR" --root "$PL_REPO" --registry "$PL_REGISTRY" \
      --manifest "$_pl_tmp_root/empty-manifest.tsv" >/dev/null 2>&1; printf '%s' "$?")"

# ── 5. The construct-fixture corpus is complete by construction ────────────────

assert_eq "#1277 the manifest and the fixture directory agree in both directions" \
  "complete" "$(python3 - "$PL_FIXTURE_DIR" <<'PL_CORPUS'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
rows = set()
for line in (d / "manifest.tsv").read_text().split("\n"):
    if line.strip() and not line.lstrip().startswith("#"):
        rows.add(line.split("\t")[1].strip())
# parse-under-bash32.sh is the per-surface fixture the registry names, parameterised
# by a path rather than a construct claim, so it is deliberately not a manifest row.
on_disk = {p.name for p in d.glob("*.sh")} - {"parse-under-bash32.sh"}
missing_row = sorted(on_disk - rows)
missing_file = sorted(rows - on_disk)
if missing_row or missing_file:
    print("orphan fixtures: %s; rows without a fixture: %s" % (missing_row, missing_file))
else:
    print("complete")
PL_CORPUS
)"

assert_eq "#1277 every construct fixture is tracked executable" \
  "" "$(git -C "$PL_REPO" ls-files -s -- lib/test/fixtures/bash32 \
      | { bad=""; while IFS= read -r row; do
            mode="${row%% *}"; path="${row##*	}"
            case "$path" in *.sh) [ "$mode" = "100755" ] || bad="$bad $path" ;; esac
          done; printf '%s' "${bad# }"; })"

assert_eq "#1277 the registry's fixture_command names the per-surface fixture that exists" \
  "present" "$([ -f "$PL_FIXTURE_DIR/parse-under-bash32.sh" ] && printf 'present' || printf 'absent')"

# ── 6. Aggregator gate: the conclusion x domain matrix ─────────────────────────

_pl_pass_file="$_pl_tmp_root/gate-pass.txt"
printf 'DOMAIN_RESULT: pass\n{"schema_version": 1}\nACTIONS_CONCLUSION: success\n' > "$_pl_pass_file"
_pl_na_file="$_pl_tmp_root/gate-na.txt"
printf 'DOMAIN_RESULT: not_applicable\n' > "$_pl_na_file"
_pl_fail_file="$_pl_tmp_root/gate-fail.txt"
printf 'DOMAIN_RESULT: fail\n' > "$_pl_fail_file"
_pl_empty_file="$_pl_tmp_root/gate-empty.txt"
: > "$_pl_empty_file"
_pl_junk_file="$_pl_tmp_root/gate-junk.txt"
printf 'DOMAIN_RESULT: probably-ok\n' > "$_pl_junk_file"

# _pl_gate <conclusion> <file> — print the gate's exit status.
_pl_gate() {
  bash "$PL_GATE" "$1" "$2" >/dev/null 2>&1
  printf '%s' "$?"
}

assert_eq "#1277 gate: success + pass is the only ordinary green" \
  "0" "$(_pl_gate success "$_pl_pass_file")"
assert_eq "#1277 gate: success + an established not_applicable is green" \
  "0" "$(_pl_gate success "$_pl_na_file")"
assert_eq "#1277 gate: success + fail is red" \
  "1" "$(_pl_gate success "$_pl_fail_file")"
assert_eq "#1277 gate: a failed producer is red even with a pass artifact" \
  "1" "$(_pl_gate failure "$_pl_pass_file")"
assert_eq "#1277 gate: a cancelled producer is red even with a pass artifact" \
  "1" "$(_pl_gate cancelled "$_pl_pass_file")"
assert_eq "#1277 gate: a skipped producer is red even with a pass artifact" \
  "1" "$(_pl_gate skipped "$_pl_pass_file")"
assert_eq "#1277 gate: an unsupplied conclusion is unestablished, not success" \
  "1" "$(_pl_gate "" "$_pl_pass_file")"
assert_eq "#1277 gate: an absent artifact is unestablished, not a pass" \
  "1" "$(_pl_gate success "$_pl_tmp_root/never-written.txt")"
assert_eq "#1277 gate: an artifact with no DOMAIN_RESULT line is unestablished" \
  "1" "$(_pl_gate success "$_pl_empty_file")"
assert_eq "#1277 gate: a domain token outside the closed set is refused" \
  "1" "$(_pl_gate success "$_pl_junk_file")"
assert_eq "#1277 gate: no artifact path at all is refused" \
  "1" "$(bash "$PL_GATE" success >/dev/null 2>&1; printf '%s' "$?")"

# Two DISAGREEING DOMAIN_RESULT lines are an ambiguity, and the gate's whole job is
# refusing to interpret an ambiguous artifact — resolving it in either direction would
# be the gate doing the one thing it exists not to do.
_pl_conflict_file="$_pl_tmp_root/gate-conflict.txt"
printf 'DOMAIN_RESULT: pass\n{"schema_version": 1}\nDOMAIN_RESULT: fail\nACTIONS_CONCLUSION: success\n' \
  > "$_pl_conflict_file"
assert_eq "#1277 gate: conflicting DOMAIN_RESULT lines are refused, not resolved" \
  "1" "$(_pl_gate success "$_pl_conflict_file")"

# A repeated but AGREEING line is not an ambiguity, so it still decides normally.
_pl_repeat_file="$_pl_tmp_root/gate-repeat.txt"
printf 'DOMAIN_RESULT: pass\nDOMAIN_RESULT: pass\nACTIONS_CONCLUSION: success\n' > "$_pl_repeat_file"
assert_eq "#1277 gate: a repeated agreeing DOMAIN_RESULT line is not an ambiguity" \
  "0" "$(_pl_gate success "$_pl_repeat_file")"

# A CRLF artifact must not present as an unrecognised token that reads byte-identical
# to a legal one; the terminator is stripped so the token decides on its own merits.
_pl_crlf_file="$_pl_tmp_root/gate-crlf.txt"
printf 'DOMAIN_RESULT: pass\r\nACTIONS_CONCLUSION: success\r\n' > "$_pl_crlf_file"
assert_eq "#1277 gate: a CRLF artifact's domain token is read without its terminator" \
  "0" "$(_pl_gate success "$_pl_crlf_file")"

# ── 7. Rendered-workflow boundary ──────────────────────────────────────────────
#
# The wiring is what makes every assertion above reachable in CI; asserting the
# helpers behave while the workflow never calls them would be a green suite over a
# lane that does not run.

_pl_ci() {
  python3 - "$PL_CI" "$1" <<'PL_CI_PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
q = sys.argv[2]
if q == "check-name":
    print(jobs["portability"]["name"])
elif q == "always":
    print(jobs["portability"].get("if"))
elif q == "needs":
    print(",".join(jobs["portability"]["needs"]))
elif q == "runner":
    print(jobs["portability_producer"]["runs-on"])
elif q == "timeout":
    print(jobs["portability_producer"].get("timeout-minutes"))
elif q == "review-needs":
    print(",".join(sorted(jobs["auto_review_trigger"]["needs"])))
elif q == "review-gates":
    # The step-level result gates must NOT mention portability: a failing lane still
    # dispatches the review.
    steps = jobs["auto_review_trigger"]["steps"]
    print("mentions" if any("portability" in str(s.get("if", "")) for s in steps) else "absent")
elif q == "gate-step":
    print(jobs["portability"]["steps"][-1]["run"].split()[1])
elif q == "bash":
    print("direct" if "--bash /bin/bash" in str(jobs["portability_producer"]["steps"]) else "indirect")
PL_CI_PY
}

assert_eq "#1277 workflow: the stable check name is the aggregator job name" \
  "portability / macOS Bash 3.2" "$(_pl_ci check-name)"
assert_eq "#1277 workflow: the aggregator runs always, so a failed producer still reports" \
  "always()" "$(_pl_ci always)"
assert_eq "#1277 workflow: the aggregator depends on the producer" \
  "portability_producer" "$(_pl_ci needs)"
assert_eq "#1277 workflow: the producer runs on macOS" \
  "macos-latest" "$(_pl_ci runner)"
assert_eq "#1277 workflow: the producer carries the 15-minute ceiling" \
  "15" "$(_pl_ci timeout)"
assert_eq "#1277 workflow: the producer invokes /bin/bash directly, not a PATH bash" \
  "direct" "$(_pl_ci bash)"
assert_eq "#1277 workflow: auto-review depends on test, lint and the portability aggregator" \
  "lint,portability,test" "$(_pl_ci review-needs)"
assert_eq "#1277 workflow: no auto-review step gates on the portability result, so a failed lane still dispatches" \
  "absent" "$(_pl_ci review-gates)"
assert_eq "#1277 workflow: the aggregator's terminal step is the gate helper" \
  "lib/test/gate-portability-result.sh" "$(_pl_ci gate-step)"
