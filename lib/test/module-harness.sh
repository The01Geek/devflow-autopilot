#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fail-closed boundary for sourceable modules used by the complete test suite.

_devflow_valid_result_count() {
  local verdict count=0
  [ -f "$RESULTS_FILE" ] && [ -r "$RESULTS_FILE" ] || return 1
  while IFS= read -r verdict || [ -n "$verdict" ]; do
    case "$verdict" in
      PASS|FAIL) count=$((count + 1)) ;;
      *) return 1 ;;
    esac
  done < "$RESULTS_FILE" || return 1
  printf '%s\n' "$count"
}

_devflow_record_module_failure() {
  if ! printf 'FAIL\n' >> "$MODULE_FAILURES_FILE"; then
    printf 'ERROR: could not record boundary failure in %s\n' \
      "$MODULE_FAILURES_FILE" >&2
    return 1
  fi
}

devflow_run_full_suite_module() { # module-path module-name minimum-assertions
  local module_path="$1" module_name="$2" minimum_assertions="$3"
  local before after module_rc assertion_count

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

  if ! before="$(_devflow_valid_result_count)"; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — result tally unreadable before module execution\n' "$module_name" >&2
    return 0
  fi

  if [ ! -f "$module_path" ] || [ ! -r "$module_path" ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — missing or unreadable: %s\n' "$module_name" "$module_path" >&2
    return 0
  fi

  (
    # Keep the full-suite boundary's fail direction identical to the focused
    # runner even when a future caller does not enable nounset globally.
    set -u
    # The module receives RESULTS_FILE by contract, but never the independent
    # boundary-failure channel used to grade its own process behavior.
    unset MODULE_FAILURES_FILE
    # shellcheck source=/dev/null disable=SC1090
    . "$module_path"
  )
  module_rc=$?

  if ! after="$(_devflow_valid_result_count)"; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — result tally unreadable after module execution\n' "$module_name" >&2
    return 0
  fi

  if [ "$module_rc" -ne 0 ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — exited with status %s\n' "$module_name" "$module_rc" >&2
  fi
  assertion_count=$((after - before))
  if [ "$assertion_count" -eq 0 ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — executed zero assertions\n' "$module_name" >&2
  elif [ "$assertion_count" -lt "$minimum_assertions" ]; then
    _devflow_record_module_failure || return 1
    printf '  FAIL  test module %s — executed %s assertions; minimum is %s\n' \
      "$module_name" "$assertion_count" "$minimum_assertions" >&2
  fi
}
