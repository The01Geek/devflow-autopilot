#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fail-closed boundary for sourceable modules used by the complete test suite.

# ── Inherited-DEVFLOW_GH fixture isolation (issue #533 AC13, generalized #695) ─
# The same clearing lib/test/run.sh performs in its preamble, performed here so
# EVERY caller that sources this harness — the complete suite AND the focused
# lib/test/run-module.sh runner — runs module bodies under identical isolation.
# The resolvers treat a non-empty DEVFLOW_GH as the strongest explicit override
# (no probe), so a value leaked in from the invoking environment would silently
# outrank every fixture-local PATH stub a module installs, making a focused run
# report environmental failures on a clean baseline. Both runners source this
# harness BEFORE any module body, so the clear always precedes module execution.
# Tests that exercise the override contract reintroduce their own value with a
# per-invocation `DEVFLOW_GH=… cmd` prefix, which is unaffected by this clear.
# Disclosed, never silent — and a no-op (no second breadcrumb) under run.sh,
# whose preamble already unset it before this file is sourced.
[ -n "${DEVFLOW_GH:-}" ] && printf 'module-harness.sh: clearing inherited DEVFLOW_GH=%s for module fixture isolation (issue #533 AC13); override-contract tests re-set their own value per-invocation\n' "$DEVFLOW_GH" >&2
unset DEVFLOW_GH

# ── Shared fixture helpers promoted from lib/test/run.sh (issue #695) ─────────
# These three were defined in the monolith and used by the installer/workflow-
# wiring coverage extracted into lib/test/modules/installer-wiring.sh. They are
# PROMOTED, not copied: lib/test/run.sh obtains them by sourcing this file, so no
# second definition exists anywhere in the tree (the coupled-mirror defect class).

# Extract one step's block from a workflow: from its `- name:` line to the
# next sibling step's `- name:` (6-space step indent, matching these workflows)
# OR the enclosing job's end (a 2-space-indented key, i.e. the next job) —
# without the job-boundary stop, a job's LAST named step would bleed into the
# following job's header and name-less steps, un-scoping the assertions run
# against the block. Matched with index() (literal substring), not a regex —
# the step names carry regex metacharacters ("(optional)").
mint_blk() {
  awk -v n="$1" '
    index($0, "- name: " n){f=1}
    f && /^      - name:/ && index($0, "- name: " n) == 0{exit}
    f && /^  [^ ]/{exit}
    f{print}' "$2"
}

# Allocate a temp file for a mutation proof, failing the SUITE (not vacuously passing) if
# mktemp fails. The anti-vacuity proofs build mutated temp copies; under `set -u`
# without `set -e` a bare `VAR="$(mktemp)"` failure would leave VAR empty, and a control
# that then reads an empty path silently degrades to its EXPECTED value (e.g. grep over ""
# prints 0, which a "expected 0" control accepts) — the anti-vacuity proof itself going
# vacuous, the exact class this helper exists to kill. On mktemp failure this records a
# suite FAIL under NAME, prints the human breadcrumb to STDERR (so it reaches the operator
# instead of being captured into the caller's `$(…)`), and prints the safe sink path
# `/dev/null` to STDOUT. The `/dev/null` is deliberate: an unguarded caller that then does
# `printf … > "$path"` or greps "$path" causes NO working-tree pollution and no spurious
# redirect error (an earlier form printed the breadcrumb itself, which a `> "$breadcrumb"`
# turned into a junk file in the repo cwd). The recorded FAIL still makes the suite go RED,
# so the proof remains fail-closed whether or not the caller checks the rc 1.
probe_tmp() {  # assertion-name -> prints a temp path (rc 0); on mktemp failure records a
               # suite FAIL, prints the breadcrumb to stderr, and prints /dev/null (rc 1)
  local t
  t="$(mktemp)" && { printf '%s\n' "$t"; return 0; }
  echo FAIL >> "$RESULTS_FILE"
  printf '  FAIL  %s — mktemp failed (mutation proof could not run; not a vacuous pass)\n' "$1" >&2
  printf '/dev/null\n'
  return 1
}

# Run a single assertion function against an ISOLATED results file and echo its verdict
# (PASS/FAIL) instead of recording it in the tally of whichever runner is executing. Used
# by the mutation proofs to actually exercise an assertion helper against a mutated target
# and confirm it goes RED, without that intentional RED counting as a failure. The
# `RESULTS_FILE=…` prefix on a function call sets the var only for that call's environment
# (functions are not special builtins), so the caller's RESULTS_FILE is untouched — the
# contract that keeps a module's executed-assertion count reflecting only real assertions.
probe_assert() {  # assertion-fn args... -> prints PASS or FAIL (the probed verdict)
  # Guard mktemp (the runners are `set -u` without `set -e`, so a bare failure would not
  # abort): an empty $probe would make `tail ""` error and the probe echo empty, surfacing
  # as a MISLEADING wrong-verdict mismatch instead of an environment failure. Emit a
  # distinct breadcrumb token so the cause is unambiguous — note it surfaces as an
  # `assert_eq` mismatch (expected PASS/FAIL, got PROBE_MKTEMP_FAILED), not a recorded
  # FAIL, so the proof still goes RED but via the comparison rather than the tally.
  # DETAILS_FILE is redirected alongside RESULTS_FILE because run-module.sh's assert_eq
  # writes a failure-recap row there on FAIL. Isolating only the tally would keep the
  # probed RED out of the assertion count but still surface it in the focused runner's
  # "Failure recap", reading as a real failure. run.sh's assert_eq has no DETAILS_FILE,
  # so the extra prefix is inert there.
  local probe; probe="$(mktemp)" || { echo "PROBE_MKTEMP_FAILED"; return 0; }
  RESULTS_FILE="$probe" DETAILS_FILE="$probe.details" "$@" >/dev/null 2>&1
  tail -n 1 "$probe"
  rm -f "$probe" "$probe.details"
}

# ── Namespaced module pin/count/mutation helpers (issue #577) ────────────────
# Shared reusable pin machinery for sourceable contract modules, so a module
# carries NO private copy of it. Caller contract: RESULTS_FILE is set and assert_eq
# is defined (both runner paths — run-module.sh and the full-suite boundary below —
# provide them). These helpers perform synchronous cleanup and install NO traps
# (the sourcing module owns the sole EXIT trap over its private temp root).
#
# devflow_module_pin_count LITERAL FILE
#   Fixed-string occurrence counter over FILE, via CHECKED python3 (a hard preflight
#   prerequisite). Prints an established non-negative integer and returns 0 ONLY
#   after a successful readable scan. On ANY failure — an unreadable file, a missing
#   or failed python3 interpreter, or malformed counter output — it prints the
#   sentinel `unestablished` (NEVER `0`) to stdout, writes a specific breadcrumb to
#   stderr, and returns 1. Returning `unestablished` rather than `0` is the whole
#   point: a fail-open `grep … || n=0` counter returns 0 on failure, so a
#   zero-expected assertion (`assert_eq … 0 "$(counter …)"`) passes vacuously; here
#   the failure value is not a number, so every consuming assertion — assert_eq or
#   the pin helpers below — records a FAIL through the assertion channel and a
#   zero-expected assertion turns RED. That is how read/interpreter/malformed-output
#   failures are recorded through the assertion channel instead of returning zero.
devflow_module_pin_count() { # literal file
  local literal="$1" file="$2" out rc
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'unestablished\n'
    printf 'devflow-module-count: unreadable file: %s\n' "$file" >&2
    return 1
  fi
  # Literal + path pass as argv (never interpolated into the program text), so a
  # literal containing quotes, `$`, or backticks cannot re-enter shell or Python
  # parsing. A non-UTF-8 read or any interpreter fault surfaces as rc != 0 below.
  out="$(python3 -c '
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()
print(sum(line.count(sys.argv[2]) for line in text.splitlines()))
' "$file" "$literal" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'unestablished\n'
    printf 'devflow-module-count: python3 counter failed (rc=%s) on: %s\n' "$rc" "$file" >&2
    return 1
  fi
  case "$out" in
    ''|*[!0-9]*)
      printf 'unestablished\n'
      printf 'devflow-module-count: malformed counter output %s on: %s\n' "${out:-(empty)}" "$file" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$out"
}

# devflow_module_pin_unique NAME LITERAL FILE
#   Exactly-one presence pin: PASS iff LITERAL occurs exactly once in FILE. An
#   unestablished count fails the assert_eq (RED), never passes as a bare "1".
devflow_module_pin_unique() { # name literal file
  assert_eq "$1" "1" "$(devflow_module_pin_count "$2" "$3")"
}

# devflow_module_pin_present NAME LITERAL FILE
#   At-least-one presence pin: PASS iff LITERAL occurs one or more times in FILE
#   (for values that legitimately recur, where an exactly-one pin would be wrong).
#   Folds an unestablished count to "no" so it fails closed (RED), never vacuously.
devflow_module_pin_present() { # name literal file
  local n
  n="$(devflow_module_pin_count "$2" "$3")"
  case "$n" in
    ''|*[!0-9]*) assert_eq "$1" "yes" "no"; return 0 ;;
  esac
  [ "$n" -ge 1 ] && assert_eq "$1" "yes" "yes" || assert_eq "$1" "yes" "no"
}

# devflow_module_pin_red_under NAME LITERAL MUTATION FILE
#   Mutation-taking scratch-copy RED proof: copies FILE to a private scratch, applies
#   the `sed -E` MUTATION to the copy (never editing the tracked FILE), and asserts
#   the pin flips PASS (exactly one occurrence in FILE) -> FAIL (not exactly one in
#   the mutated copy). A framing-only pin that survives the operative mutation reports
#   RED. An unreadable file, a mktemp failure, a sed error, or a no-op mutation each
#   record a RED verdict. Cleanup is synchronous on EVERY return path (no trap).
# #666 overbreadth bound (module copy — this harness carries NO monolith globals, so it
# duplicates the run.sh constant). The mutated scratch must retain at least 1/20 (5%) of the
# original's non-whitespace content; a blank-the-file mutation (`1,$d`, `s/.*//`) retains
# ~0 and is rejected. The 5% bound sits below the most content-destructive LEGIT mutation
# exercised anywhere (a 2-line test_module_harness.py fixture retaining ~0.154). Calibration
# is in the issue-666 workpad (module direct-site MIN retention 0.9982).
DEVFLOW_MODULE_OVERBREADTH_NUM=1
DEVFLOW_MODULE_OVERBREADTH_DEN=20
# Non-whitespace-char count via python3 (issue #736), mirroring run.sh's _nonws_count. python3
# is a hard preflight prerequisite, so guard-class 2 PERMITS it (a missing tr/wc/sed would
# silently empty this value and pass an overbroad mutation; a missing python3 fails the
# derivation instead, which this helper reports as `unestablished` so the guard verdict is RED).
# A "whitespace" char is one of exactly the six-member literal set
#   { space, tab (\t), newline (\n), carriage return (\r), form feed (\x0c), vertical tab (\x0b) }
# — complete by construction and host-independent (a fixed codepoint set, not the locale-sensitive
# `[[:space:]]` class the old bash loop used). Two files are counted in ONE interpreter process
# and published through the caller-visible globals `_MOD_NONWS_1`/`_MOD_NONWS_2` (never stdout),
# so a call site never wraps this in `$( … )` and the guard spends one invocation. On a failed
# derivation both globals become the sentinel `unestablished` and the function returns 1.
# Private to this harness (it carries NO run.sh globals, so it duplicates the derivation).
_devflow_module_nonws_count() {  # file1 [file2] -> sets _MOD_NONWS_1 [and _MOD_NONWS_2]; returns 1 on failure
  local _out _rc
  _MOD_NONWS_1=unestablished; _MOD_NONWS_2=unestablished
  _out="$(python3 -c '
import sys
_WS = frozenset("\t\n\r\x0b\x0c ")  # tab LF CR VT FF space — the six-member set (#736)
for _p in sys.argv[1:]:
    with open(_p, "rb") as _fh:
        _t = _fh.read().decode("utf-8", "surrogateescape")
    print(sum(1 for _c in _t if _c not in _WS))
' "$@" 2>/dev/null)"
  _rc=$?
  [ "$_rc" -eq 0 ] || return 1
  { IFS= read -r _MOD_NONWS_1; [ "$#" -lt 2 ] || IFS= read -r _MOD_NONWS_2; } <<< "$_out"
  case "$_MOD_NONWS_1" in ''|*[!0-9]*) _MOD_NONWS_1=unestablished; return 1 ;; esac
  if [ "$#" -ge 2 ]; then
    case "$_MOD_NONWS_2" in ''|*[!0-9]*) _MOD_NONWS_2=unestablished; return 1 ;; esac
  fi
  return 0
}
devflow_module_pin_red_under() { # name literal mutation file
  local name="$1" literal="$2" mutation="$3" file="$4" scratch before after b a _o _m
  local scratch_root="${DEVFLOW_MODULE_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    assert_eq "$name" "PASS->FAIL" "unreadable-file:$file"
    return 0
  fi
  if ! scratch="$(mktemp "$scratch_root/devflow-module-mut.XXXXXX")"; then
    assert_eq "$name" "PASS->FAIL" "mktemp-failed"
    return 0
  fi
  if ! sed -E "$mutation" "$file" > "$scratch" 2>/dev/null; then
    assert_eq "$name" "PASS->FAIL" "mutation-errored"
    rm -f "$scratch"
    return 0
  fi
  if cmp -s "$file" "$scratch"; then
    assert_eq "$name" "PASS->FAIL" "mutation-noop"
    rm -f "$scratch"
    return 0
  fi
  # #666 overbreadth guard: reject a mutation whose mutated scratch retains less than the
  # 1/DEN fraction of the original's non-whitespace content (a blank-the-file mutation).
  # Placed immediately after the cmp -s no-op guard; reports through the mutation-overbroad
  # RED token, matching the existing mutation-errored / mutation-noop shape. ONE
  # _devflow_module_nonws_count call covers both artifacts (issue #736), setting `_MOD_NONWS_1`
  # (original) and `_MOD_NONWS_2` (mutated); a failed derivation records a distinct
  # count-unestablished RED, never arithmetic on a comparand never established.
  if ! _devflow_module_nonws_count "$file" "$scratch"; then
    assert_eq "$name" "PASS->FAIL" "count-unestablished"
    rm -f "$scratch"
    return 0
  fi
  _o="$_MOD_NONWS_1"; _m="$_MOD_NONWS_2"
  if [ "$_o" -gt 0 ] && [ "$(( _m * DEVFLOW_MODULE_OVERBREADTH_DEN ))" -lt "$(( _o * DEVFLOW_MODULE_OVERBREADTH_NUM ))" ]; then
    assert_eq "$name" "PASS->FAIL" "mutation-overbroad"
    rm -f "$scratch"
    return 0
  fi
  b="$(devflow_module_pin_count "$literal" "$file")"
  a="$(devflow_module_pin_count "$literal" "$scratch")"
  before="$([ "$b" = 1 ] && printf 'PASS' || printf 'FAIL')"
  after="$([ "$a" = 1 ] && printf 'PASS' || printf 'FAIL')"
  assert_eq "$name" "PASS->FAIL" "$before->$after"
  rm -f "$scratch"
}


_devflow_valid_result_count() {
  local tally_file="${1:-$RESULTS_FILE}" invalid_count count grep_rc
  [ -f "$tally_file" ] && [ -r "$tally_file" ] || return 1

  grep_rc=0
  invalid_count="$(grep -cEv '^(PASS|FAIL)$' "$tally_file")" || grep_rc=$?
  [ "$grep_rc" -le 1 ] || return 1
  [ "$invalid_count" -eq 0 ] || return 1

  grep_rc=0
  count="$(grep -cE '^(PASS|FAIL)$' "$tally_file")" || grep_rc=$?
  [ "$grep_rc" -le 1 ] || return 1
  printf '%s\n' "$count"
}

devflow_run_focused_python_test() { # assertion-name script-path output-path
  local assertion_name="$1" script_path="$2" output_path="$3" test_rc _devflow_line

  # PYTHON_COLORS=0 keeps the captured diagnostics deterministic: a host that
  # forces color (FORCE_COLOR) would otherwise interleave ANSI codes into the
  # traceback text that downstream assertions and human readers match against.
  if PYTHON_COLORS=0 python3 "$script_path" > "$output_path" 2>&1; then
    test_rc=0
  else
    test_rc=$?
    # Pure-bash indent: piping through sed (a non-preflight PATH tool) would
    # lose the whole captured traceback when sed is absent — the diagnostics
    # must never fail open even though the verdict below fails closed.
    while IFS= read -r _devflow_line || [ -n "$_devflow_line" ]; do
      printf '    %s\n' "$_devflow_line"
    done < "$output_path"
  fi
  assert_eq "$assertion_name" "0" "$test_rc"
}

_devflow_record_module_failure() {
  if ! printf 'FAIL\n' >> "$MODULE_FAILURES_FILE"; then
    printf 'ERROR: could not record boundary failure in %s\n' \
      "$MODULE_FAILURES_FILE" >&2
    return 1
  fi
}

devflow_fold_module_failures() { # current-failure-count
  local current_failures="$1" invalid_count module_failures grep_rc

  case "$current_failures" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -f "$MODULE_FAILURES_FILE" ] && [ -r "$MODULE_FAILURES_FILE" ] || return 1

  grep_rc=0
  invalid_count="$(grep -cv '^FAIL$' "$MODULE_FAILURES_FILE")" || grep_rc=$?
  [ "$grep_rc" -le 1 ] || return 1
  [ "$invalid_count" -eq 0 ] || return 1

  grep_rc=0
  module_failures="$(grep -c '^FAIL$' "$MODULE_FAILURES_FILE")" || grep_rc=$?
  [ "$grep_rc" -le 1 ] || return 1
  printf '%s\n' "$((current_failures + module_failures))"
}

_devflow_test_write_pid() { # path pid owner
  local path="$1" pid="$2" owner="$3"
  [ -n "$path" ] || return 0
  if ! printf '%s\n' "$pid" > "$path"; then
    printf 'devflow-test: could not record %s PID in %s\n' "$owner" "$path" >&2
    return 1
  fi
}

_devflow_test_ensure_cleanup_marker() { # path marker owner
  local path="$1" marker="$2" owner="$3" line
  [ -n "$path" ] || return 0
  if [ -f "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$line" != "$marker" ] || return 0
    done < "$path"
  fi
  if ! printf '%s\n' "$marker" >> "$path"; then
    printf 'devflow-test: could not append %s cleanup marker to %s\n' \
      "$owner" "$path" >&2
    return 1
  fi
}

_devflow_test_append_cleanup_marker() { # path
  _devflow_test_ensure_cleanup_marker "$1" "runner-cleanup" "runner"
}

# devflow_module_build_bundle LABEL OUTPUT_FILE MEMBER...
#   Module-side skill-bundle builder (issue #746). Concatenates every MEMBER into
#   OUTPUT_FILE, one trailing newline per member, so a content-survival pin can
#   target the whole bundle rather than guessing which reference a sentence lives
#   in. Deliberately NOT a relocation of the monolith's `_build_skill_bundle`:
#   that one reports a bad member by writing `FAIL` straight into the caller's
#   `$RESULTS_FILE`, a raw-tally side effect a module must not perform. Here an
#   unusable member (missing, empty, unreadable, or a failed append) is reported
#   through `assert_eq`, the module contract's only sanctioned failure channel, so
#   the member's absence lands in the tally as a named RED assertion rather than
#   an anonymous one. Fails LOUD per member and keeps going, so one missing
#   reference does not mask the next; returns 1 when any member failed.
devflow_module_build_bundle() { # label output-file member...
  local label="$1" out="$2" member="" rc=0
  shift 2
  : > "$out" || {
    assert_eq "$label bundle: output file writable" "yes" "no"
    return 1
  }
  for member in "$@"; do
    if [ -r "$member" ] && [ -s "$member" ] && cat "$member" >> "$out"; then
      printf '\n' >> "$out"
    else
      # Named per member: a bare "bundle failed" cannot tell the reader WHICH
      # reference vanished, which is the whole diagnostic value of failing loud.
      assert_eq "$label bundle member usable: $member" "yes" "no"
      rc=1
    fi
  done
  return "$rc"
}

devflow_module_allocate_owned_directory() { # mktemp-template
  local template="$1" candidate="" candidate_physical="" existing=""
  local existing_physical=""
  local -a preexisting=()
  case "$template" in
    *XXXXXX) ;;
    *)
      printf 'devflow: invalid private-directory template: %s\n' "$template" >&2
      return 1
      ;;
  esac

  # Snapshot the template namespace before allocation. Standard mktemp creates
  # a fresh directory atomically; a shadowed or broken implementation must not
  # be allowed to hand cleanup a caller-owned directory that merely has the
  # expected name and parent.
  for existing in "${template%XXXXXX}"??????; do
    [ -d "$existing" ] && [ ! -L "$existing" ] || continue
    existing_physical="$(cd "$existing" 2>/dev/null && pwd -P)" || continue
    preexisting+=("$existing_physical")
  done

  candidate="$(mktemp -d "$template")" || return 1
  if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
    candidate_physical="$(cd "$candidate" 2>/dev/null && pwd -P)" || \
      candidate_physical=""
    for existing_physical in "${preexisting[@]}"; do
      if [ -n "$candidate_physical" ] && \
        [ "$candidate_physical" = "$existing_physical" ]; then
        printf 'devflow: allocator returned a pre-existing directory: %s\n' \
          "$candidate" >&2
        return 1
      fi
    done
  fi
  printf '%s\n' "$candidate"
}

_devflow_cleanup_module_scratch() { # scratch-root
  local scratch_root="$1"
  [ -n "$scratch_root" ] || return 0
  # This path is allocated by the boundary itself. Validate its generated leaf
  # before the recursive fallback so a corrupted variable cannot widen cleanup.
  case "${scratch_root##*/}" in
    devflow-module-scratch.??????) ;;
    *)
      printf 'devflow: refusing invalid module scratch root: %s\n' \
        "$scratch_root" >&2
      return 1
      ;;
  esac
  if { [ -e "$scratch_root" ] || [ -L "$scratch_root" ]; } && \
    ! rm -rf "$scratch_root"; then
    printf 'devflow: could not remove module scratch root: %s\n' \
      "$scratch_root" >&2
    return 1
  fi
  _devflow_test_ensure_cleanup_marker \
    "${DEVFLOW_TEST_MODULE_CLEANUP_MARKER:-}" "module-cleanup" "module" || return 1
}

_devflow_validate_module_scratch() { # scratch-root
  local scratch_root="$1" expected_parent actual_parent
  case "$scratch_root" in
    /*) ;;
    *) return 1 ;;
  esac
  case "${scratch_root##*/}" in
    devflow-module-scratch.??????) ;;
    *) return 1 ;;
  esac
  [ -d "$scratch_root" ] && [ ! -L "$scratch_root" ] || return 1
  expected_parent="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || return 1
  actual_parent="$(cd "$scratch_root/.." 2>/dev/null && pwd -P)" || return 1
  [ "$actual_parent" = "$expected_parent" ]
}

_devflow_discard_unvalidated_owned_directory() { # path leaf-prefix expected-parent
  local path="$1" leaf_prefix="$2" expected_parent="$3"
  local expected_physical="" actual_physical=""
  [ -n "$path" ] || return 0
  case "${path##*/}" in
    "${leaf_prefix}"??????) ;;
    *) return 0 ;;
  esac
  [ -d "$path" ] && [ ! -L "$path" ] || return 0
  expected_physical="$(cd "$expected_parent" 2>/dev/null && pwd -P)" || return 0
  actual_physical="$(cd "$path/.." 2>/dev/null && pwd -P)" || return 0
  [ "$actual_physical" = "$expected_physical" ] || return 0
  if ! rmdir -- "$path"; then
    printf 'devflow: could not discard unsafe private directory: %s\n' \
      "$path" >&2
    return 1
  fi
}

_devflow_discard_unvalidated_module_scratch() { # scratch-root
  local scratch_root="$1"
  # A rejected allocator value is removed only when it still has the exact
  # generated leaf shape and physical parent. Invalid names and traversal-shaped
  # paths are left untouched because the boundary cannot prove ownership.
  _devflow_discard_unvalidated_owned_directory "$scratch_root" \
    "devflow-module-scratch." "${TMPDIR:-/tmp}"
}

_devflow_test_read_pid() { # path
  local path="$1" pid=""
  [ -n "$path" ] && [ -r "$path" ] || return 1
  IFS= read -r pid < "$path" || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

_devflow_terminate_process_group() { # signal leader-pid grace-seconds
  local signal_name="$1" leader_pid="$2" grace_seconds="$3"
  local watchdog_pid="" monitor_was_on=0 child_rc=0
  case "$leader_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac

  kill -s "$signal_name" -- "-$leader_pid" 2>/dev/null || :
  case "$-" in
    *m*) monitor_was_on=1 ;;
    *) set -m ;;
  esac
  (
    trap '' HUP INT TERM
    sleep "$grace_seconds"
    kill -s KILL -- "-$leader_pid" 2>/dev/null || :
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$leader_pid" 2>/dev/null; then
    child_rc=0
  else
    child_rc=$?
  fi
  # The watchdog has its own process group, so cancellation terminates it and
  # its foreground sleep before the watchdog leader is reaped.
  kill -s KILL -- "-$watchdog_pid" 2>/dev/null || :
  kill -s KILL "$watchdog_pid" 2>/dev/null || :
  wait "$watchdog_pid" 2>/dev/null || :
  return "$child_rc"
}

_devflow_module_supervisor_signal() { # signal
  local signal_name="$1" escalation_timer_pid="" escalation_watchdog_pid=""
  if [ "${worker_launching:-0}" -eq 1 ]; then
    worker_pending_signal="$signal_name"
    return 0
  fi
  trap '' HUP INT TERM
  if [ -n "${supervisor_pid:-}" ]; then
    # The supervisor, worker, and foreground helpers share this group. The
    # supervisor ignores the forwarded copy while the worker/module traps run.
    kill -s "$signal_name" -- "-$supervisor_pid" 2>/dev/null || :
  fi
  if [ -n "${worker_pid:-}" ]; then
    sleep 1 >/dev/null 2>&1 &
    escalation_timer_pid=$!
    (
      trap '' HUP INT TERM
      while kill -0 "$escalation_timer_pid" 2>/dev/null; do :; done
      kill -s KILL -- "-$supervisor_pid" 2>/dev/null || :
    ) >/dev/null 2>&1 &
    escalation_watchdog_pid=$!
    wait "$worker_pid" 2>/dev/null || :
    worker_pid=""
    kill -s KILL "$escalation_timer_pid" "$escalation_watchdog_pid" \
      2>/dev/null || :
    wait "$escalation_timer_pid" 2>/dev/null || :
    wait "$escalation_watchdog_pid" 2>/dev/null || :
  fi
  exit 1
}

# Run a module body behind a shell that remains responsive while the body is
# blocked in a foreground helper. The boundary's job control gives the
# supervisor a private module group; disabling nested job control keeps the
# worker and its helpers in that group for bounded forwarding and escalation.
_devflow_supervise_module() { # body-function supervisor-pid-file worker-pid-file
  local body_function="$1" supervisor_pid_file="$2" worker_pid_file="$3"
  local supervisor_pid=""
  local worker_pid="" worker_pending_signal="" worker_launching=1
  local monitor_was_on=0 worker_rc=0
  # Bound the supervisor-PID rendezvous by WALL-CLOCK time, not an iteration
  # count. The former cap of 300 attempts consumed ~3s of `sleep 0.01`, but each
  # iteration also forks twice (the $() poll subshell and the `sleep` process),
  # so the real wall-clock cost scaled with per-fork overhead: ~3.5s on Linux and
  # enough slower on macOS (where fork/exec is costlier) to exceed the harness
  # test's 5s ceiling even though the rendezvous still failed boundedly — a
  # desk-only RED for macOS contributors, green on Linux CI (issue #641). A time
  # budget makes the bound platform-independent: the loop stops within
  # rendezvous_deadline_seconds regardless of how many polls fit in that window.
  # SECONDS is a bash builtin timer that costs no per-poll fork; its integer-
  # second granularity means the deadline actually fires anywhere in
  # [rendezvous_deadline_seconds-1, rendezvous_deadline_seconds) after the reset,
  # depending on the sub-second phase of the SECONDS=0 assignment — bounded
  # either way. rendezvous_max_polls is a fail-closed backstop that guarantees
  # termination even if SECONDS never advances (a backward system-clock step —
  # e.g. an NTP correction — after the reset would otherwise hang the loop with
  # no timeout breadcrumb): it is set far above the polls a healthy clock fits in
  # the deadline (~300 at the 10ms cadence), so it never fires first in normal
  # operation and only bounds the clock-stall case. Callers MUST run the
  # supervisor in a backgrounded ( ) subshell (both production callers do —
  # module-harness.sh full-suite and run-module.sh focused) so the non-local
  # SECONDS=0 reset stays contained to the supervisor and has no caller-visible
  # effect; a `local SECONDS` cannot be used because that strips the special
  # timer attribute.
  local rendezvous_deadline_seconds=3 rendezvous_polls=0 rendezvous_max_polls=1000

  trap '_devflow_module_supervisor_signal HUP' HUP
  trap '_devflow_module_supervisor_signal INT' INT
  trap '_devflow_module_supervisor_signal TERM' TERM
  SECONDS=0
  while ! supervisor_pid="$(_devflow_test_read_pid "$supervisor_pid_file" 2>/dev/null)"; do
    rendezvous_polls=$((rendezvous_polls + 1))
    if [ "$SECONDS" -ge "$rendezvous_deadline_seconds" ] || \
      [ "$rendezvous_polls" -ge "$rendezvous_max_polls" ]; then
      printf 'devflow: module supervisor PID rendezvous timed out: %s\n' \
        "$supervisor_pid_file" >&2
      trap - HUP INT TERM
      return 1
    fi
    sleep 0.01
  done
  case "$-" in
    *m*) monitor_was_on=1 ;;
    *) : ;;
  esac
  # Launch the worker while nested job control is disabled. Otherwise a shell
  # with a controlling TTY assigns the worker a second PGID before its body can
  # run set +m, outside the supervisor group used for forwarding and escalation.
  set +m
  _devflow_module_worker_entry() {
    # The supervisor needs one worker process group containing both the shell
    # and every foreground helper it starts. Disable nested job control inside
    # the worker so those helpers do not split into untracked process groups.
    set +m
    "$body_function"
  }
  _devflow_module_worker_entry &
  worker_pid=$!
  worker_launching=0
  [ "$monitor_was_on" -eq 0 ] || set -m
  _devflow_test_write_pid "$worker_pid_file" "$worker_pid" "module worker" || :
  _devflow_test_write_pid "${DEVFLOW_TEST_MODULE_WORKER_PID_FILE:-}" \
    "$worker_pid" "module worker" || :
  if [ -n "$worker_pending_signal" ]; then
    _devflow_module_supervisor_signal "$worker_pending_signal"
  fi
  if wait "$worker_pid"; then
    worker_rc=0
  else
    worker_rc=$?
  fi
  worker_pid=""
  trap - HUP INT TERM
  return "$worker_rc"
}

_devflow_test_pause_before_pid_capture() { # state-file
  local state_file="$1"
  [ -n "$state_file" ] || return 0
  if ! printf 'launched\n' > "$state_file"; then
    printf 'devflow-test: could not publish launch-window state: %s\n' \
      "$state_file" >&2
    return 1
  fi
  while [ ! -e "$state_file.release" ]; do
    # The hook must not become a second launch barrier after the runner has
    # already captured a pending signal for immediate replay.
    if [ -n "${MODULE_PENDING_SIGNAL:-}" ] || \
      [ -n "${module_pending_signal:-}" ]; then
      return 0
    fi
  done
}

_devflow_cleanup_full_suite_tally() { # tally-path
  local tally_path="$1"
  [ -n "$tally_path" ] || return 0
  if ! rm -f "$tally_path"; then
    printf 'devflow: could not remove private module tally: %s\n' "$tally_path" >&2
    return 1
  fi
  _devflow_test_append_cleanup_marker \
    "${DEVFLOW_TEST_RUNNER_CLEANUP_MARKER:-}" || return 1
}

_devflow_restore_signal_traps() { # saved-hup saved-int saved-term
  local saved_hup="$1" saved_int="$2" saved_term="$3"
  trap - HUP INT TERM
  # `trap -p` produced these commands in this shell; evaluating that shell-owned
  # representation preserves the caller's exact quoting and action text.
  [ -z "$saved_hup" ] || eval "$saved_hup"
  [ -z "$saved_int" ] || eval "$saved_int"
  [ -z "$saved_term" ] || eval "$saved_term"
}

# ── Run-wide live-child registry (issue #720) ────────────────────────────────
# _devflow_full_suite_signal was once a single scalar child slot (module_pid +
# module_scratch_root + module_results_file locals), so one delivered signal
# terminated ONE process group. The bounded Python-suite pool keeps several
# children live at once — and keeps them live across a module boundary that
# installs its own copy of these same traps — so a single delivered signal must
# terminate EVERY live child's group before the handler exits. This registry is
# that run-wide set: both devflow_run_full_suite_module (a single-element set)
# and devflow_pool_open register their children here, and the shared handler
# forwards to every entry. Indexed pid list + associative scratch/tally maps,
# initialized at source time so `set -u` never trips on the first ${#...[@]}.
_DEVFLOW_LIVE_CHILD_PIDS=()
declare -A _DEVFLOW_LIVE_CHILD_SCRATCH=()
declare -A _DEVFLOW_LIVE_CHILD_TALLY=()

# ── Bounded concurrent Python-suite pool state (issue #720) ───────────────────
# The pool opens at one call site (devflow_pool_open), stays open while the main
# shell runs the last module boundary and ~2000 lines of assertions, and joins at
# another (devflow_pool_join) — so its state is module-global, not call-local.
# _DEVFLOW_POOL_LAUNCHING / _DEVFLOW_POOL_PENDING_SIGNAL are the pool's launch-window guard,
# the sibling of devflow_run_full_suite_module's module_launching / pending slot.
_DEVFLOW_POOL_OPEN=0
_DEVFLOW_POOL_WIDTH=0
_DEVFLOW_POOL_LAUNCHING=0
_DEVFLOW_POOL_PENDING_SIGNAL=""
_DEVFLOW_POOL_SAVED_HUP=""
_DEVFLOW_POOL_SAVED_INT=""
_DEVFLOW_POOL_SAVED_TERM=""
_DEVFLOW_POOL_PENDING_NAMES=()
_DEVFLOW_POOL_PENDING_SCRIPTS=()
_DEVFLOW_POOL_PENDING_MODES=()
_DEVFLOW_POOL_INFLIGHT_PIDS=()
declare -A _DEVFLOW_POOL_PID_NAME=()
declare -A _DEVFLOW_POOL_PID_SCRIPT=()
declare -A _DEVFLOW_POOL_PID_MODE=()
declare -A _DEVFLOW_POOL_PID_SCRATCH=()
declare -A _DEVFLOW_POOL_PID_TALLY=()
declare -A _DEVFLOW_POOL_PID_OUTPUT=()
# Per self-tally suite (keyed by name): the PASS/FAIL line count it contributed to
# RESULTS_FILE, and its own `N passed, M failed` summary line — captured at reap so
# lib/test/run.sh can assert, positionally against that line, that a self-tally
# suite's whole assertion count reached RESULTS_FILE (issue #720; a uniformly
# dropped verdict is caught even though the width-1/width-N equality would agree).
declare -A _DEVFLOW_POOL_SELFTALLY_LINES=()
declare -A _DEVFLOW_POOL_SELFTALLY_SUMMARY=()

_devflow_register_live_child() { # pid scratch-root tally-file
  local pid="$1"
  _DEVFLOW_LIVE_CHILD_PIDS+=("$pid")
  _DEVFLOW_LIVE_CHILD_SCRATCH["$pid"]="$2"
  _DEVFLOW_LIVE_CHILD_TALLY["$pid"]="$3"
}

_devflow_deregister_live_child() { # pid
  local pid="$1" p
  local -a keep=()
  # Rebuild the pid list without $pid. The [ -gt 0 ] guard keeps an empty
  # "${keep[@]}" expansion off bash 4.0–4.3's set -u trap (same discipline as
  # _suite_cleanup's own length guards in lib/test/run.sh).
  if [ "${#_DEVFLOW_LIVE_CHILD_PIDS[@]}" -gt 0 ]; then
    for p in "${_DEVFLOW_LIVE_CHILD_PIDS[@]}"; do
      [ "$p" = "$pid" ] || keep+=("$p")
    done
  fi
  if [ "${#keep[@]}" -gt 0 ]; then
    _DEVFLOW_LIVE_CHILD_PIDS=("${keep[@]}")
  else
    _DEVFLOW_LIVE_CHILD_PIDS=()
  fi
  unset '_DEVFLOW_LIVE_CHILD_SCRATCH[$pid]'
  unset '_DEVFLOW_LIVE_CHILD_TALLY[$pid]'
}

_devflow_full_suite_signal() { # signal
  local signal_name="$1" pid scratch tally
  # The launch-window guard now covers BOTH the single-module launch
  # (module_launching, a devflow_run_full_suite_module local) AND the pool launch
  # (_DEVFLOW_POOL_LAUNCHING, a global): a signal delivered mid-launch, before the
  # child pid is registered, is stashed for replay by whichever launcher is active
  # rather than lost. Writing both pending slots is harmless — each launcher reads
  # only its own.
  if [ "${module_launching:-0}" -eq 1 ] || [ "${_DEVFLOW_POOL_LAUNCHING:-0}" -eq 1 ]; then
    module_pending_signal="$signal_name"
    _DEVFLOW_POOL_PENDING_SIGNAL="$signal_name"
    return 0
  fi
  # Ignore a second delivery while forwarding, boundedly reaping, and cleaning.
  trap '' HUP INT TERM
  # Forward to every live child's process group and clean its scratch/tally. This
  # single loop subsumes the former single module_pid slot (registered as a
  # one-element set by devflow_run_full_suite_module) and every pooled child.
  if [ "${#_DEVFLOW_LIVE_CHILD_PIDS[@]}" -gt 0 ]; then
    for pid in "${_DEVFLOW_LIVE_CHILD_PIDS[@]}"; do
      [ -n "$pid" ] || continue
      _devflow_terminate_process_group "$signal_name" "$pid" 3 || :
      scratch="${_DEVFLOW_LIVE_CHILD_SCRATCH[$pid]:-}"
      tally="${_DEVFLOW_LIVE_CHILD_TALLY[$pid]:-}"
      [ -z "$scratch" ] || _devflow_cleanup_module_scratch "$scratch" || :
      [ -z "$tally" ] || _devflow_cleanup_full_suite_tally "$tally" || :
    done
    _DEVFLOW_LIVE_CHILD_PIDS=()
  fi
  # The boundary owns only these temporary signal traps. Leave the caller's EXIT
  # trap installed so its top-level registry cleanup still runs on this exit.
  exit 1
}

# Return contract: rc 0 means the boundary HANDLED the module (including a
# failing module — the failure is recorded in MODULE_FAILURES_FILE); rc 1 means
# the boundary-failure channel itself is unusable and the caller must abort.
# rc 0 is NOT "module passed" — always fold MODULE_FAILURES_FILE afterwards.
devflow_run_full_suite_module() { # module-path module-name minimum-assertions
  local module_path="$1" module_name="$2" minimum_assertions="$3"
  local module_results_file="" module_scratch_root="" module_group_pid_file=""
  local module_worker_pid_file=""
  local module_pid="" module_rc=0 assertion_count=0 boundary_rc=0
  local module_launching=0 module_pending_signal="" tally_valid=1
  local saved_hup saved_int saved_term monitor_was_on=0

  case "$minimum_assertions" in
    ''|*[!0-9]*|????????*)
      _devflow_record_module_failure || return 1
      printf '  FAIL  test module %s — invalid minimum assertion count: %s\n' \
        "$module_name" "$minimum_assertions" >&2
      return 0
      ;;
  esac
  if [ "$minimum_assertions" -lt 1 ] || [ "$minimum_assertions" -gt 1000000 ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — invalid minimum assertion count: %s\n' \
      "$module_name" "$minimum_assertions" >&2
    return 0
  fi

  if ! _devflow_valid_result_count >/dev/null; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — result tally unreadable before module execution\n' "$module_name" >&2
    return 0
  fi

  if [ ! -f "$module_path" ] || [ ! -r "$module_path" ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — missing or unreadable: %s\n' "$module_name" "$module_path" >&2
    return 0
  fi

  if ! module_results_file="$(mktemp "${TMPDIR:-/tmp}/devflow-module-tally.XXXXXX")"; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — could not allocate private result tally\n' \
      "$module_name" >&2
    return 0
  fi
  if ! module_scratch_root="$(devflow_module_allocate_owned_directory \
    "${TMPDIR:-/tmp}/devflow-module-scratch.XXXXXX")"; then
    _devflow_cleanup_full_suite_tally "$module_results_file" || :
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — could not allocate private scratch root\n' \
      "$module_name" >&2
    return 0
  fi
  if ! _devflow_validate_module_scratch "$module_scratch_root"; then
    _devflow_discard_unvalidated_module_scratch "$module_scratch_root" || :
    module_scratch_root=""
    _devflow_cleanup_full_suite_tally "$module_results_file" || :
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — allocated an unsafe private scratch root\n' \
      "$module_name" >&2
    return 0
  fi
  module_group_pid_file="$module_scratch_root/supervisor.pid"
  module_worker_pid_file="$module_scratch_root/worker.pid"

  saved_hup="$(trap -p HUP)"
  saved_int="$(trap -p INT)"
  saved_term="$(trap -p TERM)"
  trap '_devflow_full_suite_signal HUP' HUP
  trap '_devflow_full_suite_signal INT' INT
  trap '_devflow_full_suite_signal TERM' TERM
  _devflow_test_write_pid "${DEVFLOW_TEST_RUNNER_PID_FILE:-}" "$$" \
    "full-suite runner" || :

  case "$-" in
    *m*) monitor_was_on=1 ;;
    *) set -m ;;
  esac
  module_launching=1
  (
    # Consumed by the sourced module in the worker.
    # shellcheck disable=SC2034
    DEVFLOW_MODULE_OWNED_SCRATCH_ROOT="$module_scratch_root"
    # Nest every module's ordinary TMPDIR allocations below the boundary root,
    # including modules that do not consume the DevFlow-specific ownership hint.
    TMPDIR="$module_scratch_root"
    export TMPDIR
    # Invoked indirectly by the supervisor helper.
    # shellcheck disable=SC2329
    _devflow_full_suite_module_body() {
      # Keep the full-suite boundary's fail direction identical to the focused
      # runner even when a future caller does not enable nounset globally.
      set -u
      # The module receives RESULTS_FILE by contract, but never the independent
      # boundary-failure channel, shared skip tally, or shared suite tally.
      # The private worker intentionally shadows the caller tally.
      # shellcheck disable=SC2030
      RESULTS_FILE="$module_results_file"
      unset MODULE_FAILURES_FILE
      unset SKIPS_FILE
      # shellcheck source=/dev/null disable=SC1090
      . "$module_path"
    }
    _devflow_supervise_module _devflow_full_suite_module_body \
      "$module_group_pid_file" "$module_worker_pid_file"
  ) &
  _devflow_test_pause_before_pid_capture \
    "${DEVFLOW_TEST_LAUNCH_WINDOW_FILE:-}" || :
  module_pid=$!
  _devflow_test_write_pid "$module_group_pid_file" "$module_pid" \
    "module supervisor" || :
  # Register this single child in the run-wide registry (a one-element set) so the
  # generalized signal handler forwards to it exactly as it did through the former
  # module_pid scalar slot (issue #720). Registered after the pid is known so a
  # signal that arrives before this point is caught by the module_launching guard.
  _devflow_register_live_child "$module_pid" "$module_scratch_root" \
    "$module_results_file"
  module_launching=0
  [ "$monitor_was_on" -eq 1 ] || set +m
  _devflow_test_write_pid "${DEVFLOW_TEST_MODULE_PID_FILE:-}" "$module_pid" \
    "full-suite module" || :
  if [ -n "$module_pending_signal" ]; then
    _devflow_full_suite_signal "$module_pending_signal"
  fi
  if wait "$module_pid"; then
    module_rc=0
  else
    module_rc=$?
  fi
  # Deregister on the no-signal path: the child is reaped, so a late signal must
  # not try to terminate its (now-recycled) pid or double-clean its scratch/tally
  # (the normal cleanup below owns that). The signal path never reaches here — it
  # exit 1s the whole runner after cleaning every registered child.
  _devflow_deregister_live_child "$module_pid"
  module_pid=""

  if ! assertion_count="$(_devflow_valid_result_count "$module_results_file")"; then
    tally_valid=0
    _devflow_record_module_failure || boundary_rc=1
    printf '  FAIL  test module %s — result tally unreadable after module execution\n' "$module_name" >&2
  fi

  # This is the caller tally, not the worker shadow.
  # shellcheck disable=SC2031
  if [ "$tally_valid" -eq 1 ] && ! cat "$module_results_file" >> "$RESULTS_FILE"; then
    _devflow_record_module_failure || boundary_rc=1
    printf '  FAIL  test module %s — could not append private result tally\n' \
      "$module_name" >&2
  fi
  if ! _devflow_cleanup_module_scratch "$module_scratch_root"; then
    _devflow_record_module_failure || boundary_rc=1
    printf '  FAIL  test module %s — could not remove private scratch root\n' \
      "$module_name" >&2
  fi
  module_scratch_root=""
  if ! _devflow_cleanup_full_suite_tally "$module_results_file"; then
    _devflow_record_module_failure || boundary_rc=1
    printf '  FAIL  test module %s — could not remove private result tally\n' \
      "$module_name" >&2
  fi
  module_results_file=""

  if [ "$module_rc" -ne 0 ]; then
    _devflow_record_module_failure || boundary_rc=1
    printf '  FAIL  test module %s — exited with status %s\n' "$module_name" "$module_rc" >&2
  fi
  if [ "$tally_valid" -eq 1 ] && [ "$assertion_count" -eq 0 ]; then
    _devflow_record_module_failure || boundary_rc=1
    printf '  FAIL  test module %s — executed zero assertions\n' "$module_name" >&2
  elif [ "$tally_valid" -eq 1 ] && [ "$assertion_count" -lt "$minimum_assertions" ]; then
    _devflow_record_module_failure || boundary_rc=1
    printf '  FAIL  test module %s — executed %s assertions; minimum is %s\n' \
      "$module_name" "$assertion_count" "$minimum_assertions" >&2
  fi
  # Keep the boundary traps installed through both cleanup attempts and their
  # associated failure recording.
  _devflow_restore_signal_traps "$saved_hup" "$saved_int" "$saved_term"
  return "$boundary_rc"
}

# ── Bounded concurrent Python-suite pool (issue #720) ─────────────────────────
# A generalization of devflow_run_full_suite_module from one child to a bounded
# set: it reuses that function's scratch/tally/trap-restore machinery and the same
# _devflow_supervise_module process-group launch, but keeps several suites live at
# once behind a width limit. It is opened at one call site and joined at another
# so the long pole overlaps the module boundary and the shell tail; it installs NO
# EXIT trap of its own (lib/test/run.sh's single `trap _suite_cleanup EXIT` stays
# the sole EXIT handler) and cleans every temporary it creates on its own path.
#
# Membership modes:
#   single-verdict  — the suite reports one exit status; the pool writes exactly
#                     one PASS/FAIL line to its private tally from that status
#                     (mirrors devflow_run_focused_python_test's assert_eq name 0 rc).
#   self-tally      — the suite emits one PASS/FAIL per assertion itself, into the
#                     tally path the pool exports as DEVFLOW_POOL_TALLY_FILE.
#
# Width override: the single named environment variable DEVFLOW_POOL_WIDTH takes
# precedence over the cpu_count probe when it is a positive integer; otherwise the
# width is min(os.cpu_count(), 4), falling back to 1 when that probe yields no
# positive integer. Because the cap decides a selection, it is derived through the
# preflight-guaranteed python3 (never a non-preflight PATH tool — CLAUDE.md
# guard-class 2) and a non-positive-integer probe fails closed to width 1.
_devflow_pool_resolve_width() {
  local override="${DEVFLOW_POOL_WIDTH:-}" probe
  case "$override" in
    ''|*[!0-9]*) : ;;
    *) if [ "$override" -ge 1 ]; then printf '%s\n' "$override"; return 0; fi ;;
  esac
  # DEVFLOW_TEST_POOL_CPU_PROBE substitutes the probe's OUTPUT (not a different
  # command) so a test can exercise the empty / 0 / non-numeric fallback arms;
  # +x honors an explicitly-empty injected value.
  if [ -n "${DEVFLOW_TEST_POOL_CPU_PROBE+x}" ]; then
    probe="$DEVFLOW_TEST_POOL_CPU_PROBE"
  else
    probe="$(python3 -c 'import os; print(min(os.cpu_count() or 1, 4))' 2>/dev/null)" || probe=""
  fi
  case "$probe" in
    ''|*[!0-9]*) printf '1\n'; return 0 ;;
  esac
  [ "$probe" -ge 1 ] && printf '%s\n' "$probe" || printf '1\n'
}

_devflow_pool_pending_shift() {
  local -a n=() s=() m=() ; local i
  if [ "${#_DEVFLOW_POOL_PENDING_NAMES[@]}" -gt 1 ]; then
    for ((i=1; i<${#_DEVFLOW_POOL_PENDING_NAMES[@]}; i++)); do
      n+=("${_DEVFLOW_POOL_PENDING_NAMES[$i]}")
      s+=("${_DEVFLOW_POOL_PENDING_SCRIPTS[$i]}")
      m+=("${_DEVFLOW_POOL_PENDING_MODES[$i]}")
    done
  fi
  if [ "${#n[@]}" -gt 0 ]; then
    _DEVFLOW_POOL_PENDING_NAMES=("${n[@]}"); _DEVFLOW_POOL_PENDING_SCRIPTS=("${s[@]}"); _DEVFLOW_POOL_PENDING_MODES=("${m[@]}")
  else
    _DEVFLOW_POOL_PENDING_NAMES=(); _DEVFLOW_POOL_PENDING_SCRIPTS=(); _DEVFLOW_POOL_PENDING_MODES=()
  fi
}

_devflow_pool_inflight_remove() { # pid
  local pid="$1" p ; local -a keep=()
  if [ "${#_DEVFLOW_POOL_INFLIGHT_PIDS[@]}" -gt 0 ]; then
    for p in "${_DEVFLOW_POOL_INFLIGHT_PIDS[@]}"; do
      [ "$p" = "$pid" ] || keep+=("$p")
    done
  fi
  if [ "${#keep[@]}" -gt 0 ]; then
    _DEVFLOW_POOL_INFLIGHT_PIDS=("${keep[@]}")
  else
    _DEVFLOW_POOL_INFLIGHT_PIDS=()
  fi
}

_devflow_pool_output_has_rendezvous_timeout() { # output-file
  local f="$1" line
  [ -n "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"module supervisor PID rendezvous timed out"*) return 0 ;;
    esac
  done < "$f"
  return 1
}

# The per-suite worker body: run the suite and record its verdict(s) into the
# private tally. Runs inside the supervised worker (single-verdict) or directly
# (serial retry). Fails CLOSED: a non-zero exit always yields at least one FAIL
# line, even for a self-tally suite that crashed mid-run after recording only
# PASS lines (a nonzero exit with no FAIL recorded would otherwise mask the crash).
_devflow_pool_run_one() { # name script mode tally
  local name="$1" script="$2" mode="$3" tally="$4" rc _hasfail=0 _l
  case "$mode" in
    self-tally)
      DEVFLOW_POOL_TALLY_FILE="$tally" PYTHON_COLORS=0 python3 "$script"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        while IFS= read -r _l || [ -n "$_l" ]; do
          [ "$_l" = "FAIL" ] && { _hasfail=1; break; }
        done < "$tally" 2>/dev/null
        [ "$_hasfail" -eq 1 ] || printf 'FAIL\n' >> "$tally"
      fi
      ;;
    *)
      PYTHON_COLORS=0 python3 "$script"
      rc=$?
      if [ "$rc" -eq 0 ]; then printf 'PASS\n' >> "$tally"; else printf 'FAIL\n' >> "$tally"; fi
      ;;
  esac
  return "$rc"
}

# Serial fallback for a suite whose supervisor PID rendezvous timed out under pool
# saturation (issue #720 AC): re-run it directly with no supervisor and no process
# group, so a transient rendezvous timeout is absorbed rather than recorded as a
# suite failure. Writes verdict(s) to the same private tally, and its combined stdout
# to the caller-provided OUTPUT path so the reap's self-tally summary capture still
# sees the suite's `N passed, M failed` line after a retry (issue #720 review — a
# retried self-tally suite would otherwise lose its summary and the run.sh coverage
# cross-check would inject a spurious FAIL). The reap prints OUTPUT on failure, so this
# does not print it itself.
_devflow_pool_run_serial() { # name script mode tally output
  local name="$1" script="$2" mode="$3" tally="$4" out="$5" rc
  [ -n "$out" ] || out=/dev/null
  # Test hook: record that the serial-retry path ACTUALLY executed, so a forced-timeout
  # test asserts the retry ran rather than passing vacuously when the timeout was never
  # triggered/detected (issue #720 review).
  [ -z "${DEVFLOW_TEST_POOL_RETRY_MARKER:-}" ] || \
    printf '%s\n' "$name" >> "$DEVFLOW_TEST_POOL_RETRY_MARKER" 2>/dev/null || :
  ( _devflow_pool_run_one "$name" "$script" "$mode" "$tally" ) > "$out" 2>&1
  rc=$?
  return "$rc"
}

_devflow_pool_launch_suite() { # name script mode attempt
  local name="$1" script="$2" mode="$3" attempt="$4"
  local tally scratch output group_pid_file worker_pid_file monitor_was_on=0 pid
  if ! tally="$(mktemp "${TMPDIR:-/tmp}/devflow-pool-tally.XXXXXX")"; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  pool suite %s — could not allocate private tally\n' "$name" >&2
    return 0
  fi
  # A failed output-capture mktemp falls back to /dev/null, which for a self-tally suite
  # means its `N passed, M failed` summary is never captured — the reap then records a
  # "#720 ... could not capture its summary line" FAIL that reads like a capture-logic
  # bug rather than the real cause (output tempfile allocation failed under TMPDIR
  # exhaustion/quota). Breadcrumb the real cause so that eventual FAIL is actionable
  # (best-effort: continue with /dev/null; the FAIL is fail-closed over-reporting).
  if ! output="$(mktemp "${TMPDIR:-/tmp}/devflow-pool-out.XXXXXX")"; then
    output=/dev/null
    printf 'devflow-pool: suite %s — output-capture tempfile allocation failed (TMPDIR full/quota?); a self-tally summary will be uncapturable and recorded as a FAIL downstream\n' "$name" >&2
  fi
  if ! scratch="$(devflow_module_allocate_owned_directory \
    "${TMPDIR:-/tmp}/devflow-module-scratch.XXXXXX")"; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  pool suite %s — could not allocate private scratch root\n' "$name" >&2
    rm -f "$tally"; [ "$output" = /dev/null ] || rm -f "$output"
    return 0
  fi
  if ! _devflow_validate_module_scratch "$scratch"; then
    _devflow_discard_unvalidated_module_scratch "$scratch" || :
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  pool suite %s — allocated an unsafe private scratch root\n' "$name" >&2
    rm -f "$tally"; [ "$output" = /dev/null ] || rm -f "$output"
    return 0
  fi
  group_pid_file="$scratch/supervisor.pid"
  worker_pid_file="$scratch/worker.pid"

  case "$-" in
    *m*) monitor_was_on=1 ;;
    *) set -m ;;
  esac
  _DEVFLOW_POOL_LAUNCHING=1
  (
    # Each pooled suite gets its own TMPDIR pointed at its private scratch root, so
    # every mktemp-derived temporary it (or a run-module.sh it drives) allocates is
    # isolated from the other pooled suites and from the main shell.
    TMPDIR="$scratch"
    export TMPDIR
    # Deliberately do NOT export DEVFLOW_MODULE_OWNED_SCRATCH_ROOT here (unlike
    # devflow_run_full_suite_module, which does so for the sourced shell MODULE it
    # runs): a pooled member is a standalone python3 suite that never consumes that
    # hint, and test_module_runner.py in particular EXERCISES the harness code keyed
    # on it — an inherited value would point that code at the suite's own live TMPDIR
    # and its cleanup would delete the scratch out from under the running suite
    # (issue #720). Unset any inherited value so a nested harness the suite drives
    # never sees a stale one.
    unset DEVFLOW_MODULE_OWNED_SCRATCH_ROOT
    # shellcheck disable=SC2329
    _devflow_pool_suite_body() {
      set -u
      _devflow_pool_run_one "$name" "$script" "$mode" "$tally"
    }
    _devflow_supervise_module _devflow_pool_suite_body \
      "$group_pid_file" "$worker_pid_file"
  ) > "$output" 2>&1 &
  pid=$!
  # Forced-timeout hook (issue #720 AC test): skip the supervisor PID-file write on
  # attempt 1 so the rendezvous deliberately times out and the serial-retry path is
  # exercised. Normal launches write it exactly as devflow_run_full_suite_module does.
  if [ "${DEVFLOW_POOL_FORCE_RENDEZVOUS_TIMEOUT:-}" = "$name" ] && [ "$attempt" -eq 1 ]; then
    :
  else
    _devflow_test_write_pid "$group_pid_file" "$pid" "pool supervisor" || :
  fi
  _DEVFLOW_POOL_INFLIGHT_PIDS+=("$pid")
  _DEVFLOW_POOL_PID_NAME["$pid"]="$name"
  _DEVFLOW_POOL_PID_SCRIPT["$pid"]="$script"
  _DEVFLOW_POOL_PID_MODE["$pid"]="$mode"
  _DEVFLOW_POOL_PID_SCRATCH["$pid"]="$scratch"
  _DEVFLOW_POOL_PID_TALLY["$pid"]="$tally"
  _DEVFLOW_POOL_PID_OUTPUT["$pid"]="$output"
  # Register in the run-wide live-child registry BEFORE clearing the launch-window
  # guard, mirroring devflow_run_full_suite_module's register-before-unguard ordering
  # (issue #720). A HUP/INT/TERM delivered in the window between the guard clear and
  # this registration would otherwise see both launch guards at 0 and this just-forked
  # pid still absent from _DEVFLOW_LIVE_CHILD_PIDS, so _devflow_full_suite_signal would
  # terminate the already-registered children and exit while this child is left running
  # orphaned against the checkout. With the guard still 1 across this registration, such
  # a signal is stashed in _DEVFLOW_POOL_PENDING_SIGNAL and replayed just below.
  _devflow_register_live_child "$pid" "$scratch" "$tally"
  _DEVFLOW_POOL_LAUNCHING=0
  [ "$monitor_was_on" -eq 1 ] || set +m
  if [ -n "$_DEVFLOW_POOL_PENDING_SIGNAL" ]; then
    _devflow_full_suite_signal "$_DEVFLOW_POOL_PENDING_SIGNAL"
  fi
}

_devflow_pool_launch_next() {
  local name="${_DEVFLOW_POOL_PENDING_NAMES[0]}"
  local script="${_DEVFLOW_POOL_PENDING_SCRIPTS[0]}"
  local mode="${_DEVFLOW_POOL_PENDING_MODES[0]}"
  _devflow_pool_pending_shift
  _devflow_pool_launch_suite "$name" "$script" "$mode" 1
}

_devflow_pool_reap() { # pid rc
  local pid="$1" rc="$2" _l _pool_count="" _hasfail=0
  local name="${_DEVFLOW_POOL_PID_NAME[$pid]:-?}"
  local script="${_DEVFLOW_POOL_PID_SCRIPT[$pid]:-}"
  local mode="${_DEVFLOW_POOL_PID_MODE[$pid]:-}"
  local scratch="${_DEVFLOW_POOL_PID_SCRATCH[$pid]:-}"
  local tally="${_DEVFLOW_POOL_PID_TALLY[$pid]:-}"
  local output="${_DEVFLOW_POOL_PID_OUTPUT[$pid]:-}"
  _devflow_deregister_live_child "$pid"
  _devflow_pool_inflight_remove "$pid"

  # A supervisor PID rendezvous timeout (rc != 0, empty tally, timeout marker in
  # the captured output) is absorbed by re-running the suite serially, not recorded
  # as a suite failure.
  if [ "$rc" -ne 0 ] && [ ! -s "$tally" ] && \
    _devflow_pool_output_has_rendezvous_timeout "$output"; then
    [ -z "$scratch" ] || _devflow_cleanup_module_scratch "$scratch" || :
    scratch=""
    # Reuse $output (truncated) as the serial retry's capture so the self-tally summary
    # capture below still sees the retried suite's `N passed, M failed` line — nulling
    # it here would drop the summary and inject a spurious FAIL (issue #720 review).
    if [ -n "$output" ] && [ "$output" != /dev/null ]; then
      : > "$output" 2>/dev/null || :
    elif ! output="$(mktemp "${TMPDIR:-/tmp}/devflow-pool-out.XXXXXX")"; then
      output=/dev/null
      printf 'devflow-pool: suite %s — retry output-capture tempfile allocation failed (TMPDIR full/quota?); a self-tally summary will be uncapturable and recorded as a FAIL downstream\n' "$name" >&2
    fi
    _devflow_pool_run_serial "$name" "$script" "$mode" "$tally" "$output"
    rc=$?
  fi

  # Every pooled verdict reaches PASS/FAIL through RESULTS_FILE, after validation.
  # _devflow_valid_result_count both validates the tally grammar (PASS/FAIL lines
  # only) AND prints the PASS+FAIL line count — capture that count rather than
  # re-grepping for the self-tally cross-check below.
  if _pool_count="$(_devflow_valid_result_count "$tally")"; then
    if ! cat "$tally" >> "$RESULTS_FILE"; then
      printf 'FAIL\n' >> "$RESULTS_FILE"
      printf '  FAIL  pool suite %s — could not append private tally to results\n' "$name" >&2
    fi
  else
    _pool_count=""
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  pool suite %s — private tally missing/unreadable after execution\n' "$name" >&2
  fi

  # Fail-closed guards mirroring devflow_run_full_suite_module (issue #720 review): a
  # NONZERO worker exit not already reflected as a FAIL — a kill/crash the rendezvous
  # branch did not absorb, whose worker never reached _devflow_pool_run_one's own
  # fail-closed append — and a validated-but-EMPTY tally (zero assertions) each record a
  # FAIL, so a killed or silently-empty pooled suite can never vanish with '0 failed'.
  if [ "$rc" -ne 0 ]; then
    _hasfail=0
    while IFS= read -r _l || [ -n "$_l" ]; do
      [ "$_l" = "FAIL" ] && { _hasfail=1; break; }
    done < "$tally" 2>/dev/null
    if [ "$_hasfail" -eq 0 ]; then
      printf 'FAIL\n' >> "$RESULTS_FILE"
      printf '  FAIL  pool suite %s — worker exited with status %s (no verdict recorded)\n' "$name" "$rc" >&2
    fi
  elif [ "$_pool_count" = "0" ]; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  pool suite %s — executed zero assertions\n' "$name" >&2
  fi

  if [ "$rc" -ne 0 ] && [ -n "$output" ] && [ -f "$output" ]; then
    while IFS= read -r _l || [ -n "$_l" ]; do printf '    %s\n' "$_l"; done < "$output"
  fi

  # Capture the self-tally count/summary before cleanup so run.sh can assert the
  # whole assertion count reached RESULTS_FILE (issue #720). The line count reuses
  # the validated count above; an invalid tally leaves it empty (surfaced as
  # 'unestablished' by the run.sh assertion rather than a fabricated 0).
  if [ "$mode" = "self-tally" ]; then
    _DEVFLOW_POOL_SELFTALLY_LINES["$name"]="$_pool_count"
    if [ -n "$output" ] && [ -f "$output" ]; then
      _DEVFLOW_POOL_SELFTALLY_SUMMARY["$name"]="$(grep -E '^[0-9]+ passed, [0-9]+ failed' "$output" 2>/dev/null | tail -1)"
    fi
  fi

  # A scratch-cleanup failure records a FAIL, matching devflow_run_full_suite_module's
  # boundary (issue #720 review): a pooled suite that leaks an undeletable scratch tree
  # is a real fault, not a silent best-effort skip.
  if [ -n "$scratch" ] && ! _devflow_cleanup_module_scratch "$scratch"; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  pool suite %s — could not remove private scratch root\n' "$name" >&2
  fi
  [ -z "$tally" ] || rm -f "$tally"
  [ -n "$output" ] && [ "$output" != /dev/null ] && rm -f "$output"
  unset '_DEVFLOW_POOL_PID_NAME[$pid]' '_DEVFLOW_POOL_PID_SCRIPT[$pid]' \
    '_DEVFLOW_POOL_PID_MODE[$pid]' '_DEVFLOW_POOL_PID_SCRATCH[$pid]' \
    '_DEVFLOW_POOL_PID_TALLY[$pid]' '_DEVFLOW_POOL_PID_OUTPUT[$pid]'
}

# Open the pool: resolve width, save+install the HUP/INT/TERM traps, and launch up
# to `width` suites. Args are triples: name script mode (mode ∈ single-verdict |
# self-tally). The remaining suites, if any, launch during join as slots free.
devflow_pool_open() { # name1 script1 mode1 [name2 script2 mode2 ...]
  _DEVFLOW_POOL_PENDING_NAMES=(); _DEVFLOW_POOL_PENDING_SCRIPTS=(); _DEVFLOW_POOL_PENDING_MODES=()
  _DEVFLOW_POOL_INFLIGHT_PIDS=()
  _DEVFLOW_POOL_PENDING_SIGNAL=""
  _DEVFLOW_POOL_WIDTH="$(_devflow_pool_resolve_width)"
  while [ "$#" -ge 3 ]; do
    _DEVFLOW_POOL_PENDING_NAMES+=("$1")
    _DEVFLOW_POOL_PENDING_SCRIPTS+=("$2")
    _DEVFLOW_POOL_PENDING_MODES+=("$3")
    shift 3
  done
  _DEVFLOW_POOL_SAVED_HUP="$(trap -p HUP)"
  _DEVFLOW_POOL_SAVED_INT="$(trap -p INT)"
  _DEVFLOW_POOL_SAVED_TERM="$(trap -p TERM)"
  trap '_devflow_full_suite_signal HUP' HUP
  trap '_devflow_full_suite_signal INT' INT
  trap '_devflow_full_suite_signal TERM' TERM
  _DEVFLOW_POOL_OPEN=1
  # In-flight children never exceed the resolved width: launch min(width, count).
  while [ "${#_DEVFLOW_POOL_PENDING_NAMES[@]}" -gt 0 ] && \
    [ "${#_DEVFLOW_POOL_INFLIGHT_PIDS[@]}" -lt "$_DEVFLOW_POOL_WIDTH" ]; do
    _devflow_pool_launch_next
  done
}

# Join the pool: reap every in-flight child (launching pending suites as slots free
# so the width limit still holds), append each verdict to RESULTS_FILE, then restore
# the caller's signal traps. Installs no EXIT trap; leaves _suite_cleanup the sole
# EXIT handler. Must be called before the RESULTS_FILE tally is counted.
devflow_pool_join() {
  [ "${_DEVFLOW_POOL_OPEN:-0}" -eq 1 ] || return 0
  local pid rc
  while [ "${#_DEVFLOW_POOL_INFLIGHT_PIDS[@]}" -gt 0 ]; do
    pid="${_DEVFLOW_POOL_INFLIGHT_PIDS[0]}"
    if wait "$pid"; then rc=0; else rc=$?; fi
    _devflow_pool_reap "$pid" "$rc"
    if [ "${#_DEVFLOW_POOL_PENDING_NAMES[@]}" -gt 0 ]; then
      _devflow_pool_launch_next
    fi
  done
  _devflow_restore_signal_traps "$_DEVFLOW_POOL_SAVED_HUP" \
    "$_DEVFLOW_POOL_SAVED_INT" "$_DEVFLOW_POOL_SAVED_TERM"
  _DEVFLOW_POOL_OPEN=0
}
