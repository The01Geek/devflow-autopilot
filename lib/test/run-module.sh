#!/usr/bin/env bash
# Experimental manifest-backed test-module runner. Selection and validation
# finish before the selected module is sourced.

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
REGISTRY="$REPO_ROOT/scripts/workflow-flight-recorder-registry.json"
LOG_DIR="$REPO_ROOT/.prflow/tmp/test-module-logs"
MODULE_ID=""
# Assigned unconditionally (issue #890), never defaulted with `:-` off the environment:
# this is what makes an inherited MODULE_HEAVY_UNIT_MODE structurally unable to shrink
# what a run executes. Only --heavy-units below changes it.
#
# `export -n` for the same reason lib/test/run.sh applies it to DEVFLOW_SKIP_SUITE_MODULES:
# bash PRESERVES the export attribute of a variable inherited from the environment, so
# without this an already-exported MODULE_HEAVY_UNIT_MODE would carry whatever this runner
# assigns — including a `--heavy-units smoke` — into every process launched underneath it.
# The module body is sourced in a subshell of this shell, so it still reads the value.
MODULE_HEAVY_UNIT_MODE=full
export -n MODULE_HEAVY_UNIT_MODE 2>/dev/null || true
HEAVY_UNITS_SEEN=

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
  printf 'Usage: bash lib/test/run-module.sh [--registry PATH] [--log-dir PATH] [--heavy-units full|smoke] MODULE\n' >&2
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
    --heavy-units)
      # How much of a module's heaviest unit to run (issue #890) — see
      # devflow_run_sharded_python_test in lib/test/module-harness.sh for what each mode
      # means. `full` is the default, and no module shard passes this flag — asserted by
      # the #890 argv probe in lib/test/run.sh, which drives the shard dispatcher; the
      # complete suite never invokes this script at all, reaching modules through
      # devflow_run_full_suite_module, which assigns `full` unconditionally. Where the flag
      # is passed to make a module actually bound something, that is the meta-test in
      # lib/test/test_module_runner.py, which passes
      # `smoke` because it drives a module end-to-end purely to prove the runner drives it,
      # and must not pay that module's whole population a second time in the same CI run;
      # the flag's own behavior tests in that same file drive it against a fixture module.
      # A decision this consequential is a FLAG rather than an inherited environment read,
      # so it is visible at the call site that chose it rather than acquired from an
      # ambient variable.
      [ "$#" -ge 2 ] || { usage; selector_error "--heavy-units requires full or smoke"; }
      # Refuse a repeat rather than silently taking the last one. The flag's premise is
      # that the population is visible at the call site that chose it; a caller that
      # believes it pinned `full` and is overridden later in its own argv gets no signal,
      # which is the same silence the misspelled-value arm below already refuses.
      [ -z "$HEAVY_UNITS_SEEN" ] || { usage; selector_error "--heavy-units given more than once"; }
      HEAVY_UNITS_SEEN=1
      # Consumed by the dynamically selected module sourced in the worker, and read again
      # by this script itself for the unrequested-bound check and the bounded-run notice.
      case "$2" in
        full|smoke) MODULE_HEAVY_UNIT_MODE="$2" ;;
        *) usage; selector_error "--heavy-units takes full or smoke, not '$2'" ;;
      esac
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
SKIPS_FILE=""
CREDIT_FILE=""
MODULE_PID=""
MODULE_SCRATCH_ROOT=""
MODULE_GROUP_PID_FILE=""
MODULE_WORKER_PID_FILE=""
MODULE_LAUNCHING=0
MODULE_PENDING_SIGNAL=""
RUNNER_CLEANUP_DONE=0
cleanup() {
  local cleanup_rc=0
  [ "$RUNNER_CLEANUP_DONE" -eq 0 ] || return 0
  [ -z "$SELECTOR_STDERR" ] || rm -f "$SELECTOR_STDERR" || cleanup_rc=1
  # `.names` is record_fail's identifier record (issue #789), whose path is DERIVED from
  # RESULTS_FILE — module-harness.sh defines record_fail and this runner sources it, so a
  # focused run whose probe_tmp or pool arm fails writes one here too. Removed alongside
  # the tally it belongs to rather than left as /tmp litter.
  [ -z "$RESULTS_FILE" ] || rm -f "$RESULTS_FILE" "$RESULTS_FILE.names" || cleanup_rc=1
  [ -z "$DETAILS_FILE" ] || rm -f "$DETAILS_FILE" || cleanup_rc=1
  # The private skip tally and skip-credit record (issue #887), siblings of the tally
  # above: the focused `skip` override writes a host-capability declaration here rather
  # than to stdout, so a module-authored reason never reaches the log the unrequested-
  # bound guard scans.
  [ -z "$SKIPS_FILE" ] || rm -f "$SKIPS_FILE" || cleanup_rc=1
  [ -z "$CREDIT_FILE" ] || rm -f "$CREDIT_FILE" || cleanup_rc=1
  _devflow_cleanup_module_scratch "$MODULE_SCRATCH_ROOT" || cleanup_rc=1
  _devflow_test_append_cleanup_marker \
    "${DEVFLOW_TEST_RUNNER_CLEANUP_MARKER:-}" || cleanup_rc=1
  [ "$cleanup_rc" -ne 0 ] || RUNNER_CLEANUP_DONE=1
  return "$cleanup_rc"
}
cleanup_on_signal() {
  local signal_name="$1"
  if [ "$MODULE_LAUNCHING" -eq 1 ]; then
    MODULE_PENDING_SIGNAL="$signal_name"
    return 0
  fi
  # Ignore a second delivery while forwarding, boundedly reaping, and cleaning.
  trap '' HUP INT TERM
  if [ -n "$MODULE_PID" ]; then
    _devflow_terminate_process_group "$signal_name" "$MODULE_PID" 3 || :
    MODULE_PID=""
  fi
  cleanup || :
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
    # PRESENCE is the test, not truthiness: `mapping.get(...) is not None` cannot tell an
    # ABSENT key from one explicitly set to JSON `null`, so a `"assertion_floor_policy":
    # null` row was accepted exactly like an omitted field. That is the wrong direction —
    # the reconciler selects its measurement population on this field being the string
    # `exact`, so a null silently drops that module out of the exact-floor set while the
    # registry reads as though the author had declared a policy for it.
    if "assertion_floor_policy" in mapping:
        assertion_floor_policy = mapping["assertion_floor_policy"]
        if assertion_floor_policy != "exact":
            selector_error(
                f"mapping for {registered_id!r}: assertion_floor_policy must be "
                "'exact' when present"
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
# The private skip tally and skip-credit record (issue #887). Bound into the worker
# below (SKIPS_FILE is inherited; MODULE_SKIP_CREDIT_FILE points at CREDIT_FILE) so a
# module's module_host_capability_skip declaration records here instead of aborting the
# focused runner, and the parent folds it after `wait` exactly as the full-suite boundary
# does — a visible skip with its assertion credit applied, never a laundered clean pass.
SKIPS_FILE="$(mktemp "${TMPDIR:-/tmp}/devflow-module-skips.XXXXXX")" || \
  selector_error "could not allocate the skip tally"
CREDIT_FILE="$(mktemp "${TMPDIR:-/tmp}/devflow-module-credits.XXXXXX")" || \
  selector_error "could not allocate the skip-credit record"
MODULE_SCRATCH_ROOT="$(devflow_module_allocate_owned_directory \
  "${TMPDIR:-/tmp}/devflow-module-scratch.XXXXXX")" || \
  selector_error "could not allocate the module scratch root"
if ! _devflow_validate_module_scratch "$MODULE_SCRATCH_ROOT"; then
  _devflow_discard_unvalidated_module_scratch "$MODULE_SCRATCH_ROOT" || :
  MODULE_SCRATCH_ROOT=""
  selector_error "allocated an unsafe module scratch root"
fi
MODULE_GROUP_PID_FILE="$MODULE_SCRATCH_ROOT/supervisor.pid"
MODULE_WORKER_PID_FILE="$MODULE_SCRATCH_ROOT/worker.pid"
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
MODULE_LAUNCHING=1
(
  # Consumed by the sourced module in the worker.
  # shellcheck disable=SC2034
  DEVFLOW_MODULE_OWNED_SCRATCH_ROOT="$MODULE_SCRATCH_ROOT"
  # Contain ordinary module/helper TMPDIR allocations inside the boundary root
  # so forced group termination still has a complete cleanup fallback.
  TMPDIR="$MODULE_SCRATCH_ROOT"
  export TMPDIR
  # Invoked indirectly by the supervisor helper.
  # shellcheck disable=SC2329
  _devflow_focused_module_body() {
    set -u
    # Consumed by the dynamically selected module sourced below.
    # shellcheck disable=SC2034
    LIB="$REPO_ROOT/lib"
    # Consumed by module_host_capability_skip (module-harness.sh) in the sourced module:
    # its assertion-credit declaration lands here, and the parent applies it against the
    # module's floor after `wait` (issue #887). SKIPS_FILE is inherited from the parent.
    # shellcheck disable=SC2034
    MODULE_SKIP_CREDIT_FILE="$CREDIT_FILE"

    sanitize_result_field() {
      local value="$1"
      value="${value//$'\t'/ }"
      value="${value//$'\r'/ }"
      value="${value//$'\n'/\\n}"
      printf '%s' "${value:-(empty)}"
    }

    skip() {
      # Two paths reach this override (issue #887). A `module_host_capability_skip`
      # declaration (module-harness.sh) delegates here with the sanction marker set for
      # the duration of its call; that is a legitimate host-capability skip, so the
      # focused runner now HAS a skip channel — it records the declaration to the private
      # skip tally and returns, and the parent folds it into a visible skip with its
      # assertion credit applied. A RAW `skip` a module invokes directly never carries
      # the marker (nor a `host-capability` kind), so it stays a fatal contract violation.
      # The two paths are distinguished by the marker, and that distinction is covered by
      # an executed test in test_module_runner.py, not by inspection.
      local _sk_name="${1:-}" _sk_kind="${2:-}" _sk_reason="${3:-}"
      if [ "${_DEVFLOW_SANCTIONED_HOST_CAPABILITY_SKIP:-}" = 1 ] && [ "$_sk_kind" = host-capability ]; then
        # Write the declaration to the private skip tally, NOT to stdout: the parent
        # emits the itemized `  SKIP  ` line AFTER its BOUNDED-smoke-subset scan of the
        # log, so a module-authored reason — even one that happens to contain the literal
        # `BOUNDED smoke subset` — cannot reach that scan and trip the unrequested-bound
        # failure predicate. Field shape and sanitization mirror run.sh's skip()
        # (kind<TAB>name<TAB>reason, bash-builtin collapse of TAB/NL/CR — guard-class 2).
        local _sk_name_clean="${_sk_name//[$'\t'$'\n'$'\r']/ }"
        [ -n "$_sk_name_clean" ] || _sk_name_clean="(unnamed check)"
        printf 'host-capability\t%s\t%s\n' \
          "$_sk_name_clean" "${_sk_reason//[$'\t'$'\n'$'\r']/ }" >> "$SKIPS_FILE" || {
          printf 'FATAL: could not record host-capability skip\n' >&2; exit 1; }
        return 0
      fi
      # The first clause is the durable literal callers assert on.
      printf 'FATAL: modules may not self-skip (module contract) — keep skippable gates in the full suite.\n' >&2
      printf 'If this came from module_host_capability_skip the declaration is legitimate and the focused runner folds it as a skip; reaching this fatal means a RAW skip crossed the module contract boundary.\n' >&2
      exit 1
    }

    assert_eq() {
      local name="$1" expected="$2" actual="$3"
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
  }
  _devflow_supervise_module _devflow_focused_module_body \
    "$MODULE_GROUP_PID_FILE" "$MODULE_WORKER_PID_FILE"
) > "$LOG_FILE" 2>&1 &
_devflow_test_pause_before_pid_capture \
  "${DEVFLOW_TEST_LAUNCH_WINDOW_FILE:-}" || :
MODULE_PID=$!
_devflow_test_write_pid "$MODULE_GROUP_PID_FILE" "$MODULE_PID" \
  "module supervisor" || :
MODULE_LAUNCHING=0
[ "$RUNNER_MONITOR_WAS_ON" -eq 1 ] || set +m
_devflow_test_write_pid "${DEVFLOW_TEST_MODULE_PID_FILE:-}" "$MODULE_PID" \
  "focused module" || :
if [ -n "$MODULE_PENDING_SIGNAL" ]; then
  cleanup_on_signal "$MODULE_PENDING_SIGNAL"
fi
if wait "$MODULE_PID"; then
  MODULE_RC=0
else
  MODULE_RC=$?
fi
MODULE_PID=""
MODULE_CLEANUP_FAILED=0
if _devflow_cleanup_module_scratch "$MODULE_SCRATCH_ROOT"; then
  MODULE_SCRATCH_ROOT=""
else
  MODULE_CLEANUP_FAILED=1
fi

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

# An UNREQUESTED bound is a failure (issue #890). Everything else in the guard chain
# establishes what this runner was ASKED for — its own unconditional `full`, the
# --heavy-units flag, the #890 argv probe over the shard dispatcher. None of them can see
# the last link: a module that forwards a literal `smoke`, or defaults to one, bounds its
# heaviest unit while every tally stays green, the summary is unchanged, and the notice
# below does not fire (it reads this runner's mode, not the module's behavior). That would
# remove the bounded unit's full population from CI silently, which is exactly the
# reduction this flag exists to make deliberate. So when `full` was requested, the module's
# own log must carry no bound: the driver states one in its tally line, and finding that
# clause here is a contradiction between what was asked and what ran.
#
# The scan is a bash `case` over the log's lines, never `grep`: this value decides an
# emitted result (the failure tally), and a non-preflight PATH tool would let a missing or
# erroring `grep` yield "no bound found" — a vacuous pass in the reducing direction.
UNREQUESTED_BOUND=0
if [ "$MODULE_HEAVY_UNIT_MODE" = full ] && [ -r "$LOG_FILE" ]; then
  while IFS= read -r _hu_line || [ -n "$_hu_line" ]; do
    case "$_hu_line" in
      *"BOUNDED smoke subset"*) UNREQUESTED_BOUND=1; break ;;
    esac
  done < "$LOG_FILE"
fi

# Fold the private skip tally and skip-credit record (issue #887). The focused `skip`
# override writes ONLY `host-capability`-kinded lines here (a raw skip is fatal and never
# records), so a line of any other shape is a contract breach counted as a failure. The
# credit sum lowers the module's effective floor exactly as the full-suite boundary does,
# so a host taking a gated arm reports a visible skip instead of a floor trip that reads
# like a regression. Read with bash builtins, never grep/awk: these values decide an
# EMITTED result (the failure tally and the skip suffix) and a SELECTION (the floor the
# assertion count is compared against) — guard-class 2 bars a non-preflight PATH tool.
#
# The unreadable-record arms below mirror the full-suite boundary's, for the same reason
# it states: `-s` distinguishes "nothing was recorded" (the common case, a clean no-op)
# from a file that exists WITH content, and a non-empty-but-unreadable record is neither —
# the redirect fails, the loop body never runs, and the records vanish silently. Without
# the arm that silence is fail-OPEN in the one direction that matters: the skips disappear
# from the summary while a still-readable credit record keeps lowering EFFECTIVE_MIN, so a
# module could clear a relaxed floor and report a byte-clean pass. A lost skip record
# therefore also FORFEITS every credit — crediting the floor while the skips themselves are
# invisible is exactly the laundering this channel exists to prevent.
SKIP_COUNT=0
SKIP_MALFORMED_COUNT=0
SKIP_RECORDS_LOST=0
if [ -s "$SKIPS_FILE" ] && [ ! -r "$SKIPS_FILE" ]; then
  SKIP_RECORDS_LOST=1
elif [ -r "$SKIPS_FILE" ]; then
  while IFS= read -r _sk_line || [ -n "$_sk_line" ]; do
    [ -n "$_sk_line" ] || continue
    case "$_sk_line" in
      "host-capability"$'\t'*) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
      *) SKIP_MALFORMED_COUNT=$((SKIP_MALFORMED_COUNT + 1)) ;;
    esac
  done < "$SKIPS_FILE"
fi
SKIP_CREDIT_TOTAL=0
SKIP_CREDIT_MALFORMED=0
SKIP_CREDIT_UNREADABLE=0
if [ -s "$CREDIT_FILE" ] && [ ! -r "$CREDIT_FILE" ]; then
  SKIP_CREDIT_UNREADABLE=1
elif [ -r "$CREDIT_FILE" ]; then
  while IFS= read -r _cr_line || [ -n "$_cr_line" ]; do
    [ -n "$_cr_line" ] || continue
    case "$_cr_line" in
      # Digits only, and short enough that the arithmetic below cannot overflow — the
      # same bounded-digit shape the assertion floor uses. `10#` forces base 10 so a
      # leading-zero credit is decimal, never an octal reinterpretation.
      ''|*[!0-9]*|????????*) SKIP_CREDIT_MALFORMED=$((SKIP_CREDIT_MALFORMED + 1)) ;;
      *) SKIP_CREDIT_TOTAL=$((SKIP_CREDIT_TOTAL + 10#$_cr_line)) ;;
    esac
  done < "$CREDIT_FILE"
fi
# A credit that meets or exceeds the floor would leave nothing for the floor to assert, so
# it is rejected and the RAW minimum stands — fail closed toward the stricter bound.
# A lost skip record forfeits every credit first (see the unreadable arm above), so the raw
# minimum stands and the shortfall is reported rather than credited away.
SKIP_CREDIT_REJECTED=0
if [ "$SKIP_RECORDS_LOST" -ne 0 ]; then
  SKIP_CREDIT_TOTAL=0
elif [ "$SKIP_CREDIT_TOTAL" -ge "$MIN_ASSERTIONS" ]; then
  SKIP_CREDIT_REJECTED=1
  SKIP_CREDIT_TOTAL=0
fi
EFFECTIVE_MIN=$((MIN_ASSERTIONS - SKIP_CREDIT_TOTAL))

EXTRA_FAIL_COUNT=0
[ "$UNREQUESTED_BOUND" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$INVALID_RESULT_COUNT" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$MODULE_RC" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$MODULE_CLEANUP_FAILED" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$SKIP_MALFORMED_COUNT" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$SKIP_CREDIT_MALFORMED" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$SKIP_CREDIT_REJECTED" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$SKIP_RECORDS_LOST" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
[ "$SKIP_CREDIT_UNREADABLE" -eq 0 ] || EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
ASSERTION_COUNT=$((PASS_COUNT + ASSERT_FAIL_COUNT))
if [ "$ASSERTION_COUNT" -eq 0 ]; then
  EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
elif [ "$ASSERTION_COUNT" -lt "$EFFECTIVE_MIN" ]; then
  EXTRA_FAIL_COUNT=$((EXTRA_FAIL_COUNT + 1))
fi
FAIL_COUNT=$((ASSERT_FAIL_COUNT + EXTRA_FAIL_COUNT))

{
  # The summary line stays BYTE-IDENTICAL to the pre-#887 shape when no skip fired, so
  # test_module_runner.py's exact `Module <id>: N passed, M failed` membership assertions
  # and the assertion-count triple are unaffected. A skip appends the optional `, K skipped`
  # tally clause — the same shape lib/test/shard-tally.py's `_BARE_SUMMARY` already models
  # and lib/test/summary.sh renders — and the itemized `  SKIP  ` lines follow. This is a
  # TALLY (it goes on the tally line), distinct from the bounded-run NOTICE below (which is
  # not a tally and stays on its own line): the machine-consumed contract permits extending
  # the tally line with the optional trailing skip clause, and lib/test/shard-tally.py's
  # `_MODULE_SUMMARY` regex is updated in the same change to read it (issue #887).
  if [ "$SKIP_COUNT" -gt 0 ]; then
    printf '\nModule %s: %s passed, %s failed, %s skipped\n' \
      "$MODULE_ID" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  else
    printf '\nModule %s: %s passed, %s failed\n' "$MODULE_ID" "$PASS_COUNT" "$FAIL_COUNT"
  fi
  # Itemized `  SKIP  <name> [host-capability] — <reason>` lines (issue #456: a skip is
  # never laundered into a clean pass). Emitted from the PRIVATE skip tally, and only HERE
  # — after the unrequested-bound scan above has finished reading the log — so a module-
  # authored reason cannot reach that scan. Field split with bash builtins (guard-class 2).
  if [ "$SKIP_COUNT" -gt 0 ] && [ -r "$SKIPS_FILE" ]; then
    while IFS= read -r _sk_line || [ -n "$_sk_line" ]; do
      case "$_sk_line" in
        "host-capability"$'\t'*)
          # The focused skip override emits name<TAB>reason (an empty reason still leaves
          # the trailing TAB), so every record IT writes carries both fields. It is not
          # the only possible writer, though — SKIPS_FILE is inherited and a module can
          # append to it, which is exactly why SKIP_MALFORMED_COUNT exists. A hand-written
          # single-field line passes that guard and takes the `#*\t` fallback, rendering
          # the name a second time as the reason. Benign under this file's stated threat
          # model (a test harness, not a sandbox) — noted so the shape is not mistaken for
          # an invariant the split relies on.
          _sk_rest="${_sk_line#host-capability$'\t'}"
          _sk_name="${_sk_rest%%$'\t'*}"
          _sk_reason="${_sk_rest#*$'\t'}"
          printf '  SKIP  %s [host-capability] — %s\n' "$_sk_name" "$_sk_reason"
          ;;
      esac
    done < "$SKIPS_FILE"
  fi
  # A bounded run is a coverage reduction, and the summary line above cannot express one:
  # its shape is a machine-consumed contract (lib/test/shard-tally.py anchors a regex on it
  # end to end, and step-8 real-runner meta-tests assert it as an exact splitlines()
  # member), so the notice is its own line rather than a suffix. What it buys is a HUMAN
  # signal in the shard's uploaded log — the recombined gate summary cannot express a bound
  # at all, since shard-tally.py parses only the anchored summary line; the unrequested-
  # bound failure above is what makes a reduction gate-visible. Absent this notice a reader
  # of the raw log would see a bounded run's tally and a full run's as byte-identical, the
  # same "a reduced run is never a clean pass" rule issue #456 established for skips.
  #
  # It reports what was REQUESTED, and says so, because that is all this scope can
  # establish: only a module that reads the mode bounds anything, so requesting `smoke` for
  # a module that ignores it yields a full run. Whether a unit actually bounded its
  # population is the driver's own tally line, above this one in the same log.
  if [ "$MODULE_HEAVY_UNIT_MODE" != full ]; then
    printf 'Module %s: heavy units REQUESTED bounded (--heavy-units %s) — a module that reads this mode did NOT execute its full population; see the driver tally above\n' \
      "$MODULE_ID" "$MODULE_HEAVY_UNIT_MODE"
  fi
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf 'Failure recap:\n'
    while IFS=$'\t' read -r name expected actual || [ -n "$name$expected$actual" ]; do
      printf '  - %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    done < "$DETAILS_FILE"
    if [ "$UNREQUESTED_BOUND" -ne 0 ]; then
      printf '  - module bounded a heavy unit that was not requested (--heavy-units %s was in effect)\n' \
        "$MODULE_HEAVY_UNIT_MODE"
    fi
    if [ "$INVALID_RESULT_COUNT" -ne 0 ]; then
      printf '  - assertion tally contained %s invalid record(s)\n' "$INVALID_RESULT_COUNT"
    fi
    if [ "$MODULE_RC" -ne 0 ]; then
      printf '  - module process exited with status %s\n' "$MODULE_RC"
    fi
    if [ "$MODULE_CLEANUP_FAILED" -ne 0 ]; then
      printf '  - module scratch cleanup failed\n'
    fi
    if [ "$SKIP_MALFORMED_COUNT" -ne 0 ]; then
      printf '  - skip tally contained %s non-host-capability record(s) (a module may not self-skip)\n' \
        "$SKIP_MALFORMED_COUNT"
    fi
    if [ "$SKIP_CREDIT_MALFORMED" -ne 0 ]; then
      printf '  - skip-credit record contained %s malformed declaration(s)\n' \
        "$SKIP_CREDIT_MALFORMED"
    fi
    if [ "$SKIP_CREDIT_REJECTED" -ne 0 ]; then
      printf '  - skip-assertion credit met or exceeded the assertion floor %s and was rejected\n' \
        "$MIN_ASSERTIONS"
    fi
    if [ "$SKIP_RECORDS_LOST" -ne 0 ]; then
      printf '  - private skip tally is unreadable; every skip credit was forfeited\n'
    fi
    if [ "$SKIP_CREDIT_UNREADABLE" -ne 0 ]; then
      printf '  - private skip-credit record is unreadable\n'
    fi
    if [ "$ASSERTION_COUNT" -eq 0 ]; then
      printf '  - module executed zero assertions\n'
    elif [ "$ASSERTION_COUNT" -lt "$EFFECTIVE_MIN" ]; then
      # The credited clause is appended only when a credit was actually granted, so an
      # uncredited run's message stays byte-identical to the pre-#887 text.
      if [ "$SKIP_CREDIT_TOTAL" -gt 0 ]; then
        printf '  - module executed %s assertions; minimum is %s (effective %s after %s credited skip assertions)\n' \
          "$ASSERTION_COUNT" "$MIN_ASSERTIONS" "$EFFECTIVE_MIN" "$SKIP_CREDIT_TOTAL"
      else
        printf '  - module executed %s assertions; minimum is %s\n' \
          "$ASSERTION_COUNT" "$MIN_ASSERTIONS"
      fi
    fi
  fi
  printf 'Log: %s\n' "$LOG_FILE"
} >> "$LOG_FILE"

RUN_RC=0
cat "$LOG_FILE" || RUN_RC=1
[ "$FAIL_COUNT" -eq 0 ] || RUN_RC=1
cleanup || RUN_RC=1
trap - EXIT
exit "$RUN_RC"
