#!/usr/bin/env bash
# Experimental manifest-backed test-module runner. Selection and validation
# finish before the selected module is sourced.

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
REGISTRY="$REPO_ROOT/scripts/workflow-flight-recorder-registry.json"
LOG_DIR="$REPO_ROOT/.devflow/tmp/test-module-logs"
MODULE_ID=""

# Fail closed on BOTH the source and its outcome: a failed top-level `.` does
# not stop bash (no set -e here), and the floor is only an incidental backstop —
# with any floor slack a missing harness would run the module green while its
# focused Python suites silently never execute (guard-class 1: verify the
# outcome, not the precondition).
# shellcheck source=lib/test/module-harness.sh disable=SC1091
. "$TEST_DIR/module-harness.sh" || {
  printf 'selector error: could not source %s\n' "$TEST_DIR/module-harness.sh" >&2
  exit 2
}
type devflow_run_focused_python_test >/dev/null 2>&1 || {
  printf 'selector error: module-harness.sh did not define devflow_run_focused_python_test\n' >&2
  exit 2
}

usage() {
  printf 'Usage: bash lib/test/run-module.sh [--registry PATH] [--log-dir PATH] MODULE\n' >&2
}

selector_error() {
  printf 'selector error: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry)
      [ "$#" -ge 2 ] || { usage; selector_error "--registry requires a path"; }
      REGISTRY="$2"
      shift 2
      ;;
    --log-dir)
      [ "$#" -ge 2 ] || { usage; selector_error "--log-dir requires a path"; }
      LOG_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage
      selector_error "unknown option '$1'"
      ;;
    *)
      [ -z "$MODULE_ID" ] || { usage; selector_error "exactly one module id is required"; }
      MODULE_ID="$1"
      shift
      ;;
  esac
done

[ -n "$MODULE_ID" ] || { usage; selector_error "exactly one module id is required"; }

case "$REGISTRY" in
  /*) ;;
  *) REGISTRY="$REPO_ROOT/$REGISTRY" ;;
esac
case "$LOG_DIR" in
  /*) ;;
  *) LOG_DIR="$REPO_ROOT/$LOG_DIR" ;;
esac

SELECTOR_STDERR=""
RESULTS_FILE=""
DETAILS_FILE=""
MODULE_PID=""
RUNNER_CLEANUP_DONE=0
cleanup() {
  [ "$RUNNER_CLEANUP_DONE" -eq 0 ] || return 0
  RUNNER_CLEANUP_DONE=1
  [ -z "$SELECTOR_STDERR" ] || rm -f "$SELECTOR_STDERR"
  [ -z "$RESULTS_FILE" ] || rm -f "$RESULTS_FILE"
  [ -z "$DETAILS_FILE" ] || rm -f "$DETAILS_FILE"
  _devflow_test_append_cleanup_marker \
    "${DEVFLOW_TEST_RUNNER_CLEANUP_MARKER:-}" || :
}
cleanup_on_signal() {
  local signal_name="$1"
  # Process-group delivery can reach the runner and module concurrently. Ignore
  # duplicates while the runner forwards, reaps, and cleans exactly once.
  trap '' HUP INT TERM
  if [ -n "$MODULE_PID" ]; then
    # Job control gives the module a distinct process group, so forwarding also
    # reaches any foreground helper the module shell is waiting for.
    kill -s "$signal_name" -- "-$MODULE_PID" 2>/dev/null || :
    wait "$MODULE_PID" 2>/dev/null || :
    MODULE_PID=""
  fi
  cleanup
  trap - EXIT
  exit 1
}
trap cleanup EXIT
# Trap HUP/INT/TERM explicitly so cleanup runs at a deterministic point and the
# runner exits 1 (not 128+sig). The module is supervised in the background below,
# so a parent-only signal can forward to and reap it before removing the tallies.
trap 'cleanup_on_signal HUP' HUP
trap 'cleanup_on_signal INT' INT
trap 'cleanup_on_signal TERM' TERM

# Explicit ${TMPDIR:-/tmp}-rooted templates: bare `mktemp` does not honor a
# runtime TMPDIR override on macOS/BSD (it uses the Darwin confstr temp dir),
# so a bare call would silently ignore the caller's TMPDIR (CLAUDE.md: no
# GNU-only behavior assumptions).
SELECTOR_STDERR="$(mktemp "${TMPDIR:-/tmp}/devflow-module-selector.XXXXXX")" || \
  selector_error "could not allocate selector diagnostics"
MODULE_SELECTION="$(python3 - "$REGISTRY" "$MODULE_ID" "$REPO_ROOT" 2>"$SELECTOR_STDERR" <<'PY'
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys


registry_path = Path(sys.argv[1])
module_id = sys.argv[2]
repo_root = Path(sys.argv[3]).resolve()


def selector_error(message: str) -> None:
    print(f"selector error: {message}", file=sys.stderr)
    raise SystemExit(2)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate registry key {key!r}")
        result[key] = value
    return result


if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", module_id):
    selector_error(f"invalid module id {module_id!r}")

try:
    document = json.loads(
        registry_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object
    )
except (OSError, json.JSONDecodeError, UnicodeError, ValueError) as error:
    # Carry the cause: a duplicate-key ValueError or a permission OSError would
    # otherwise be misread as a JSON-syntax problem.
    selector_error(f"registry is unreadable or malformed: {registry_path} ({error})")

if (
    not isinstance(document, dict)
    or type(document.get("schema_version")) is not int
    or document["schema_version"] != 1
):
    selector_error("registry requires integer schema_version 1")

modules = document.get("test_modules")
if not isinstance(modules, dict) or not modules:
    selector_error("registry test_modules must be a non-empty object")

allowed_root = (repo_root / "lib/test/modules").resolve()


def resolve_mapping(registered_id: str, mapping: object) -> tuple[Path, int]:
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", registered_id):
        selector_error(f"registry contains invalid module id {registered_id!r}")
    if not isinstance(mapping, dict):
        selector_error(f"mapping for {registered_id!r} must be an object")
    module_path_value = mapping.get("path")
    if not isinstance(module_path_value, str) or not re.fullmatch(
        r"lib/test/modules/[A-Za-z0-9][A-Za-z0-9._-]*[.]sh", module_path_value
    ):
        selector_error(
            f"mapping for {registered_id!r}: module path must match "
            "lib/test/modules/<name>.sh"
        )
    try:
        module_path = (repo_root / module_path_value).resolve(strict=True)
        module_path.relative_to(allowed_root)
    except (OSError, ValueError):
        selector_error(
            f"mapping for {registered_id!r}: module path is missing or escapes "
            f"lib/test/modules: {module_path_value}"
        )
    if not module_path.is_file() or not os.access(module_path, os.R_OK):
        selector_error(
            f"mapping for {registered_id!r}: module path is not a readable file: "
            f"{module_path_value}"
        )
    minimum_assertions = mapping.get("minimum_assertions")
    if (
        type(minimum_assertions) is not int
        or minimum_assertions < 1
        or minimum_assertions > 1_000_000
    ):
        selector_error(
            f"mapping for {registered_id!r}: minimum_assertions must be an integer "
            "from 1 to 1000000"
        )
    return module_path, minimum_assertions


resolved_modules = {
    registered_id: resolve_mapping(registered_id, mapping)
    for registered_id, mapping in modules.items()
}
if module_id not in resolved_modules:
    available = ", ".join(sorted(resolved_modules))
    selector_error(f"unknown test module {module_id!r}; available: {available}")

selected_path, selected_minimum = resolved_modules[module_id]
print(selected_path)
print(selected_minimum)
PY
)"
SELECTOR_RC=$?
if [ "$SELECTOR_RC" -ne 0 ]; then
  cat "$SELECTOR_STDERR" >&2
  exit 2
fi
rm -f "$SELECTOR_STDERR"
SELECTOR_STDERR=""
case "$MODULE_SELECTION" in
  *$'\n'*) ;;
  *) selector_error "selected mapping did not provide path and assertion floor" ;;
esac
MODULE_PATH="${MODULE_SELECTION%%$'\n'*}"
MIN_ASSERTIONS="${MODULE_SELECTION#*$'\n'}"
# Re-validate both tuple fields at the consumer (the selector prints the path
# verbatim, so a pathological path could smuggle extra lines into the tuple; a
# non-numeric floor would make the later [ -lt ] comparison error inside an
# elif and silently skip the assertion-floor gate — a fail-open).
[ -n "$MODULE_PATH" ] || selector_error "selected mapping resolved an empty module path"
case "$MIN_ASSERTIONS" in
  # Same case pattern as the harness sibling: digits only, fewer than 8 chars
  # (the selector already range-checks 1..1,000,000 upstream; an unbounded
  # digit string would overflow the later [ -lt ] comparison — the fail-open
  # this closes).
  ''|*[!0-9]*|????????*) selector_error "selected mapping did not provide a numeric assertion floor" ;;
esac

# No log directory or module-side effect exists before the exact selection above
# succeeds. The tallies are allocated BEFORE the persistent log so a failed
# tally allocation can never leave an empty, summary-less log behind.
RESULTS_FILE="$(mktemp "${TMPDIR:-/tmp}/devflow-module-results.XXXXXX")" || \
  selector_error "could not allocate the assertion tally"
DETAILS_FILE="$(mktemp "${TMPDIR:-/tmp}/devflow-module-details.XXXXXX")" || {
  selector_error "could not allocate failure details"
}
mkdir -p "$LOG_DIR" || selector_error "could not create log directory: $LOG_DIR"
LOG_FILE="$(mktemp "$LOG_DIR/$MODULE_ID.log.XXXXXX")" || \
  selector_error "could not allocate module log in: $LOG_DIR"
_devflow_test_write_pid "${DEVFLOW_TEST_RUNNER_PID_FILE:-}" "$$" \
  "focused runner" || :

RUNNER_MONITOR_WAS_ON=0
case "$-" in
  *m*) RUNNER_MONITOR_WAS_ON=1 ;;
  *) set -m ;;
esac
(
  set -u
  # Consumed by the dynamically selected module sourced below.
  # shellcheck disable=SC2034
  LIB="$REPO_ROOT/lib"

  sanitize_result_field() {
    local value="$1"
    value="${value//$'\t'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/\\n}"
    printf '%s' "${value:-(empty)}"
  }

  # Enforce the module contract's no-self-skip rule on THIS tier too: without
  # this stub a stray `skip` is a non-fatal rc-127 mid-module (no set -e), so
  # the focused run would stay green while the full-suite boundary fails the
  # same module closed — a focused-vs-full-suite verdict divergence.
  skip() {
    printf 'FATAL: modules may not self-skip (module contract) — keep skippable gates in the full suite\n' >&2
    exit 1
  }

  assert_eq() {
    local name="$1" expected="$2" actual="$3"
    # Tally appends are checked (mirrors _devflow_record_module_failure's
    # contract): a lost record must abort the module process loudly, never
    # silently thin the count the floor is graded on.
    if [ "$expected" = "$actual" ]; then
      printf 'PASS\n' >> "$RESULTS_FILE" || {
        printf 'FATAL: could not record assertion result\n' >&2; exit 1; }
      printf '  PASS  %s\n' "$name"
    else
      printf 'FAIL\n' >> "$RESULTS_FILE" || {
        printf 'FATAL: could not record assertion result\n' >&2; exit 1; }
      printf '%s\t%s\t%s\n' \
        "$(sanitize_result_field "$name")" \
        "$(sanitize_result_field "$expected")" \
        "$(sanitize_result_field "$actual")" >> "$DETAILS_FILE" || {
        printf 'FATAL: could not record failure details\n' >&2; exit 1; }
      printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' \
        "$name" "$expected" "$actual"
    fi
  }

  if [ "${DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE:-}" = "1" ]; then
    assert_eq "controlled experimental failure injection" "disabled" "enabled"
  fi

  # shellcheck source=/dev/null disable=SC1090
  . "$MODULE_PATH"
) > "$LOG_FILE" 2>&1 &
MODULE_PID=$!
[ "$RUNNER_MONITOR_WAS_ON" -eq 1 ] || set +m
_devflow_test_write_pid "${DEVFLOW_TEST_MODULE_PID_FILE:-}" "$MODULE_PID" \
  "focused module" || :
if wait "$MODULE_PID"; then
  MODULE_RC=0
else
  MODULE_RC=$?
fi
MODULE_PID=""

PASS_COUNT=0
ASSERT_FAIL_COUNT=0
INVALID_RESULT_COUNT=0
while IFS= read -r verdict || [ -n "$verdict" ]; do
  case "$verdict" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) ASSERT_FAIL_COUNT=$((ASSERT_FAIL_COUNT + 1)) ;;
    *) INVALID_RESULT_COUNT=$((INVALID_RESULT_COUNT + 1)) ;;
  esac
done < "$RESULTS_FILE"

EXTRA_FAIL_COUNT=0
[ "$INVALID_RESULT_COUNT" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$MODULE_RC" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
ASSERTION_COUNT=$((PASS_COUNT + ASSERT_FAIL_COUNT))
if [ "$ASSERTION_COUNT" -eq 0 ]; then
  EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
elif [ "$ASSERTION_COUNT" -lt "$MIN_ASSERTIONS" ]; then
  EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
fi
FAIL_COUNT=$((ASSERT_FAIL_COUNT + EXTRA_FAIL_COUNT))

{
  printf '\nModule %s: %s passed, %s failed\n' "$MODULE_ID" "$PASS_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf 'Failure recap:\n'
    while IFS=$'\t' read -r name expected actual || [ -n "$name$expected$actual" ]; do
      printf '  - %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    done < "$DETAILS_FILE"
    if [ "$INVALID_RESULT_COUNT" -ne 0 ]; then
      printf '  - assertion tally contained %s invalid record(s)\n' "$INVALID_RESULT_COUNT"
    fi
    if [ "$MODULE_RC" -ne 0 ]; then
      printf '  - module process exited with status %s\n' "$MODULE_RC"
    fi
    if [ "$ASSERTION_COUNT" -eq 0 ]; then
      printf '  - module executed zero assertions\n'
    elif [ "$ASSERTION_COUNT" -lt "$MIN_ASSERTIONS" ]; then
      printf '  - module executed %s assertions; minimum is %s\n' \
        "$ASSERTION_COUNT" "$MIN_ASSERTIONS"
    fi
  fi
  printf 'Log: %s\n' "$LOG_FILE"
} >> "$LOG_FILE"

cat "$LOG_FILE" || exit 1
[ "$FAIL_COUNT" -eq 0 ]
