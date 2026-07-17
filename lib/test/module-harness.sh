#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fail-closed boundary for sourceable modules used by the complete test suite.

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
  local assertion_name="$1" script_path="$2" output_path="$3" test_rc

  if python3 "$script_path" > "$output_path" 2>&1; then
    test_rc=0
  else
    test_rc=$?
    sed 's/^/    /' "$output_path"
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

devflow_run_full_suite_module() { # module-path module-name minimum-assertions
  local module_path="$1" module_name="$2" minimum_assertions="$3"
  local module_results_file="" module_rc assertion_count

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

  if ! module_results_file="$(mktemp)"; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — could not allocate private result tally\n' \
      "$module_name" >&2
    return 0
  fi

  (
    # Keep the full-suite boundary's fail direction identical to the focused
    # runner even when a future caller does not enable nounset globally.
    set -u
    # The module receives RESULTS_FILE by contract, but never the independent
    # boundary-failure channel or the shared suite tally used to grade its own
    # process behavior. A private tally prevents an over-broad module write from
    # changing any verdict recorded before this boundary.
    RESULTS_FILE="$module_results_file"
    unset MODULE_FAILURES_FILE
    # shellcheck source=/dev/null disable=SC1090
    . "$module_path"
  )
  module_rc=$?

  if ! assertion_count="$(_devflow_valid_result_count "$module_results_file")"; then
    rm -f "$module_results_file"
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — result tally unreadable after module execution\n' "$module_name" >&2
    return 0
  fi

  if ! cat "$module_results_file" >> "$RESULTS_FILE"; then
    rm -f "$module_results_file"
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — could not append private result tally\n' \
      "$module_name" >&2
    return 0
  fi
  rm -f "$module_results_file"

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
