#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fail-closed boundary for sourceable modules used by the complete test suite.

_devflow_valid_result_count() {
  local verdict count=0
  while IFS= read -r verdict || [ -n "$verdict" ]; do
    case "$verdict" in
      PASS|FAIL) count=$((count + 1)) ;;
    esac
  done < "$RESULTS_FILE" || return 1
  printf '%s\n' "$count"
}

devflow_run_full_suite_module() { # module-path module-name
  local module_path="$1" module_name="$2" before after module_rc

  if ! before="$(_devflow_valid_result_count)"; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  test module %s — result tally unreadable before module execution\n' "$module_name" >&2
    return 0
  fi

  if [ ! -f "$module_path" ] || [ ! -r "$module_path" ]; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  test module %s — missing or unreadable: %s\n' "$module_name" "$module_path" >&2
    return 0
  fi

  (
    # Keep the full-suite boundary's fail direction identical to the focused
    # runner even when a future caller does not enable nounset globally.
    set -u
    # shellcheck source=/dev/null disable=SC1090
    . "$module_path"
  )
  module_rc=$?

  if ! after="$(_devflow_valid_result_count)"; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  test module %s — result tally unreadable after module execution\n' "$module_name" >&2
    return 0
  fi

  if [ "$module_rc" -ne 0 ]; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  test module %s — exited with status %s\n' "$module_name" "$module_rc" >&2
  fi
  if [ "$after" -le "$before" ]; then
    printf 'FAIL\n' >> "$RESULTS_FILE"
    printf '  FAIL  test module %s — executed zero assertions\n' "$module_name" >&2
  fi
}
