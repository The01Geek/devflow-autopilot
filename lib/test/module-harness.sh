#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fail-closed boundary for sourceable modules used by the complete test suite.

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
devflow_module_pin_red_under() { # name literal mutation file
  local name="$1" literal="$2" mutation="$3" file="$4" scratch before after b a
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

_devflow_test_append_cleanup_marker() { # path
  local path="$1"
  [ -n "$path" ] || return 0
  if ! printf 'runner-cleanup\n' >> "$path"; then
    printf 'devflow-test: could not append runner cleanup marker to %s\n' "$path" >&2
    return 1
  fi
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

_devflow_full_suite_signal() { # signal module-pid tally-path
  local signal_name="$1" module_pid="$2" tally_path="$3"
  # Process-group delivery can reach this handler and the module concurrently;
  # ignore duplicate signals while forwarding, reaping, and cleaning.
  trap '' HUP INT TERM
  if [ -n "$module_pid" ]; then
    # The supervised module is its own job-control process group, so forwarding
    # reaches both the shell and any foreground helper it is waiting for.
    kill -s "$signal_name" -- "-$module_pid" 2>/dev/null || :
    wait "$module_pid" 2>/dev/null || :
  fi
  _devflow_cleanup_full_suite_tally "$tally_path" || :
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
  local module_results_file="" module_pid="" module_rc assertion_count
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

  saved_hup="$(trap -p HUP)"
  saved_int="$(trap -p INT)"
  saved_term="$(trap -p TERM)"
  trap '_devflow_full_suite_signal HUP "$module_pid" "$module_results_file"' HUP
  trap '_devflow_full_suite_signal INT "$module_pid" "$module_results_file"' INT
  trap '_devflow_full_suite_signal TERM "$module_pid" "$module_results_file"' TERM
  _devflow_test_write_pid "${DEVFLOW_TEST_RUNNER_PID_FILE:-}" "$$" \
    "full-suite runner" || :

  case "$-" in
    *m*) monitor_was_on=1 ;;
    *) set -m ;;
  esac
  (
    # Keep the full-suite boundary's fail direction identical to the focused
    # runner even when a future caller does not enable nounset globally.
    set -u
    # The module receives RESULTS_FILE by contract, but never the independent
    # boundary-failure channel, the shared skip tally, or the shared suite tally
    # used to grade its own process behavior. A private tally prevents an
    # over-broad module write from changing any verdict recorded before this
    # boundary. (Deliberate dialect note: on an invalid record the full suite
    # voids the module's whole private tally as unreadable, while the focused
    # runner counts the valid records and adds one failure — full-suite
    # contamination voids the contribution; focused runs preserve diagnostics.)
    RESULTS_FILE="$module_results_file"
    unset MODULE_FAILURES_FILE
    unset SKIPS_FILE
    # shellcheck source=/dev/null disable=SC1090
    . "$module_path"
  ) &
  module_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m
  _devflow_test_write_pid "${DEVFLOW_TEST_MODULE_PID_FILE:-}" "$module_pid" \
    "full-suite module" || :
  if wait "$module_pid"; then
    module_rc=0
  else
    module_rc=$?
  fi
  module_pid=""
  _devflow_restore_signal_traps "$saved_hup" "$saved_int" "$saved_term"

  if ! assertion_count="$(_devflow_valid_result_count "$module_results_file")"; then
    _devflow_cleanup_full_suite_tally "$module_results_file" || :
    module_results_file=""
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — result tally unreadable after module execution\n' "$module_name" >&2
    return 0
  fi

  if ! cat "$module_results_file" >> "$RESULTS_FILE"; then
    _devflow_cleanup_full_suite_tally "$module_results_file" || :
    module_results_file=""
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — could not append private result tally\n' \
      "$module_name" >&2
    return 0
  fi
  _devflow_cleanup_full_suite_tally "$module_results_file" || :
  module_results_file=""

  if [ "$module_rc" -ne 0 ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — exited with status %s\n' "$module_name" "$module_rc" >&2
  fi
  if [ "$assertion_count" -eq 0 ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — executed zero assertions\n' "$module_name" >&2
  elif [ "$assertion_count" -lt "$minimum_assertions" ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — executed %s assertions; minimum is %s\n' \
      "$module_name" "$assertion_count" "$minimum_assertions" >&2
  fi
}
