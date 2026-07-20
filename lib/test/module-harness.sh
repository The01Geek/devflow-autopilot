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
  # budget makes the bound platform-independent: on any host the loop exits
  # ~3s after starting regardless of how many polls fit in that window. SECONDS
  # is a bash builtin timer that costs no per-poll fork; the supervisor runs
  # inside a backgrounded ( ) subshell in both production callers
  # (module-harness.sh full-suite and run-module.sh focused), so resetting it
  # here has no caller-visible effect.
  local rendezvous_deadline_seconds=3

  trap '_devflow_module_supervisor_signal HUP' HUP
  trap '_devflow_module_supervisor_signal INT' INT
  trap '_devflow_module_supervisor_signal TERM' TERM
  SECONDS=0
  while ! supervisor_pid="$(_devflow_test_read_pid "$supervisor_pid_file" 2>/dev/null)"; do
    if [ "$SECONDS" -ge "$rendezvous_deadline_seconds" ]; then
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

_devflow_full_suite_signal() { # signal
  local signal_name="$1"
  if [ "${module_launching:-0}" -eq 1 ]; then
    module_pending_signal="$signal_name"
    return 0
  fi
  # Ignore a second delivery while forwarding, boundedly reaping, and cleaning.
  trap '' HUP INT TERM
  if [ -n "${module_pid:-}" ]; then
    _devflow_terminate_process_group "$signal_name" "$module_pid" 3 || :
    module_pid=""
  fi
  _devflow_cleanup_module_scratch "${module_scratch_root:-}" || :
  module_scratch_root=""
  _devflow_cleanup_full_suite_tally "${module_results_file:-}" || :
  module_results_file=""
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
