#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# ---8<--- help-start
# In-run parallel full-suite coordinator for agent verification (issue #1086).
#
# CI already partitions this suite: `lib/test/run-shard.sh` maps a shard name to its
# work and several shard JOBS run concurrently on separate runners, recombined by
# `lib/test/shard-tally.py combine`. An agent's final verification gate had no such
# partition available — it ran `lib/test/run.sh` as one serial process — so every
# final and recovery pass paid the serial wall-clock and pushed the whole assertion
# stream back into model context.
#
# This script runs that SAME tested partition concurrently inside ONE checkout and
# prints a compact aggregate. It is the single agent-facing command shape:
#
#   lib/test/run-parallel.sh          run the suite in parallel, print the aggregate
#   lib/test/run-parallel.sh --help   this header
#
# The bare form is the whole contract on purpose. Every environment assignment,
# redirect, background process, capacity decision and aggregation lives INSIDE this
# script, because the cloud permission matcher refuses caller-side assignment,
# redirect, pipeline and interpreter-prefix shapes even when the head is granted
# (issues #363/#401/#455). A caller that has to spell any of those to run the suite
# is a caller whose command is silently denied.
#
# `lib/test/run.sh` stays the serial primitive: the `monolith` shard runs it, and the
# documented uncovered-surface fallback still names it. Focused modules
# (`lib/test/run-module.sh <id>`) stay the iteration default. This script is the
# FINAL gate, not the iteration loop.
#
# Differences from CI that the timing here does NOT let you infer:
#   * CI isolates each shard on its own runner; these shards share one host's CPU,
#     memory, checkout and process namespace.
#   * CI's wall-clock is the slowest RUNNER; this script's is the slowest shard
#     under contention with its siblings.
#
# Environment (all optional):
#   DEVFLOW_SUITE_PROCESS_BUDGET  positive integer; overrides the cpu probe (also the
#                                 test seam). Absent/nonnumeric/nonpositive OVERRIDE
#                                 falls through to the probe; a probe that yields no
#                                 positive integer fails closed to 1.
#   DEVFLOW_SHARD_DISPATCHER      path to a shard dispatcher other than the sibling
#                                 run-shard.sh (fixtures only).
#   TMPDIR                        fallback run-root parent when the checkout is
#                                 read-only.
#
# Exit status: 0 only when the aggregate is clean. Every named failure below exits
# non-zero with a `run-parallel:`-prefixed diagnostic naming what could not be done —
# including a shard whose process exited non-zero even when its tally reads clean.
#
# KNOWN EXPOSURE, stated rather than assumed away: CI has only ever run these shards in
# SEPARATE checkouts on separate runners. Running them in one checkout under deliberate
# CPU saturation is new, and this coordinator isolates each shard's TMPDIR and tally
# directory but NOT repo-relative writes a shard's own assertions may make. A red result
# here that a serial `lib/test/run.sh` does not reproduce is therefore a signal to
# investigate the assertion's isolation or its slack budget — not something to re-run
# and hope on (this repository keeps no known-flake set).
# ---8<--- help-end

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

DISPATCHER="${DEVFLOW_SHARD_DISPATCHER:-$SCRIPT_DIR/run-shard.sh}"
TALLY_HELPER="$SCRIPT_DIR/shard-tally.py"

# Per detail class, not a shared budget — see shard-tally.py's --detail-cap.
DETAIL_CAP=20
# The largest total process budget this coordinator will schedule against, however
# many CPUs the host reports. Above this the shards contend more than they overlap,
# and the nested Python pool multiplies the pressure.
BUDGET_CEILING=8
# The most slots the nested `python-pool` reservation may take (its own width cap).
POOL_RESERVATION_CEILING=4

die() { # message
  printf 'run-parallel: %s\n' "$1" >&2
  exit 2
}

[ "$#" -le 1 ] || die "this command takes no arguments — the agent-facing command shape is the bare invocation"
case "${1-}" in
  '') ;;
  --help|-h)
    # Delimited by sentinels rather than line numbers: a hardcoded `4,50p` range silently
    # truncates or overspills the moment any header line is added or removed, and nothing
    # would go red. `sed` is not preflight-guaranteed, so its absence is announced rather
    # than printing nothing and exiting 0.
    if ! sed -n '/^# ---8<--- help-start/,/^# ---8<--- help-end/{/---8<---/d;p;}' "$0" | sed 's/^# \{0,1\}//'; then
      printf 'run-parallel: could not render --help (sed is unavailable); read the header of %s instead\n' "$0" >&2
      exit 2
    fi
    exit 0
    ;;
  *)
    die "unknown argument '$1' — the agent-facing command shape is the bare invocation"
    ;;
esac

# ── Reentrancy ───────────────────────────────────────────────────────────────
# A shard runs modules, and a module that invoked THIS script against the real
# population would fork a whole second suite underneath a shard of the first. The
# guard is scoped to a real-population invocation: a fixture invocation naming its
# own dispatcher is exactly how the focused module exercises this coordinator, and
# refusing that would make the module untestable from inside the suite it verifies.
if [ -n "${DEVFLOW_PARALLEL_SUITE_ACTIVE:-}" ] && [ -z "${DEVFLOW_SHARD_DISPATCHER:-}" ]; then
  die "reentrancy: a parallel suite run is already active in this process tree; the real shard population must not be re-entered from inside a shard"
fi

# ── Shard population (derived, never copied) ─────────────────────────────────
[ -x "$DISPATCHER" ] || [ -r "$DISPATCHER" ] || \
  die "shard dispatcher is not readable: $DISPATCHER"
# The dispatcher's own stderr is deliberately NOT swallowed: this diagnostic names
# which step failed, and the dispatcher names why.
SHARDS="$(bash "$DISPATCHER" --list-shards)" || \
  die "shard dispatcher failed to list its shards: $DISPATCHER --list-shards"

SHARD_COUNT=0
SEEN_SHARDS=""
for shard in $SHARDS; do
  # Validate before the name reaches a path. A malformed name is a dispatcher
  # defect, and letting it through would silently create a run-root sibling
  # outside the layout the isolation argument below depends on.
  case "$shard" in
    ''|*[!a-z0-9-]*|-*) die "malformed shard name from the dispatcher: '$shard'" ;;
  esac
  # Uniqueness is the other half of that isolation argument, and its absence is
  # silent in the dangerous direction: two shards of the same name write ONE tally
  # directory and one log, `combine` reads that directory twice (doubling its counts
  # and satisfying --expect from a single shard), and the shard the typo displaced
  # never runs at all — coverage vanishes while the gate stays green.
  case " $SEEN_SHARDS " in
    *" $shard "*) die "duplicate shard name from the dispatcher: '$shard' — two shards would share one tally directory and a displaced shard would silently not run" ;;
  esac
  SEEN_SHARDS="$SEEN_SHARDS $shard"
  SHARD_COUNT=$((SHARD_COUNT + 1))
done
[ "$SHARD_COUNT" -gt 0 ] || \
  die "the shard dispatcher returned an empty population; refusing to report a clean suite over zero shards"

# ── Run root ─────────────────────────────────────────────────────────────────
# Fresh per invocation, so a stale sibling's tally directory can never be mistaken
# for this run's (the aggregation below also passes explicit paths, never a scan).
_try_run_root() { # parent -> prints a fresh writable run root, or returns 1
  local parent="$1" candidate n=0
  [ -n "$parent" ] || return 1
  mkdir -p "$parent" 2>/dev/null || return 1
  while [ "$n" -lt 50 ]; do
    candidate="$parent/run-$$-$n"
    # `mkdir` without -p is the atomic claim: it fails if the name already exists,
    # so two coordinators racing on the same parent cannot pick the same root.
    if mkdir "$candidate" 2>/dev/null; then
      # Existence is not writability (a read-only mount, a full quota): verify the
      # outcome the root stands in for rather than the precondition.
      if : > "$candidate/.writable" 2>/dev/null; then
        rm -f "$candidate/.writable"
        printf '%s\n' "$candidate"
        return 0
      fi
      rmdir "$candidate" 2>/dev/null || :
      return 1
    fi
    n=$((n + 1))
  done
  return 1
}

RUN_ROOT="$(_try_run_root "$REPO_ROOT/.prflow/tmp/parallel-suite")" || RUN_ROOT=""
if [ -z "$RUN_ROOT" ]; then
  RUN_ROOT="$(_try_run_root "${TMPDIR:-/tmp}/devflow-parallel-suite")" || RUN_ROOT=""
  [ -n "$RUN_ROOT" ] || \
    die "could not allocate a writable run root under $REPO_ROOT/.prflow/tmp/parallel-suite or ${TMPDIR:-/tmp}/devflow-parallel-suite (read-only, full, or name space exhausted)"
  printf 'run-parallel: checkout run root unusable; retained logs are under %s\n' "$RUN_ROOT" >&2
fi
mkdir -p "$RUN_ROOT/logs" "$RUN_ROOT/tally" "$RUN_ROOT/tmp" 2>/dev/null || \
  die "could not create the run-root layout under $RUN_ROOT"

# ── Process budget ───────────────────────────────────────────────────────────
# The budget decides a SELECTION (how much overlaps), so it is derived through the
# preflight-guaranteed python3 and never a non-preflight PATH tool (CLAUDE.md
# guard-class 2). An override that is not a positive integer is not silently
# honoured; an unestablished probe fails closed to a serial-but-complete width 1.
BUDGET=""
case "${DEVFLOW_SUITE_PROCESS_BUDGET:-}" in
  ''|*[!0-9]*) : ;;
  *) [ "${DEVFLOW_SUITE_PROCESS_BUDGET}" -ge 1 ] && BUDGET="$DEVFLOW_SUITE_PROCESS_BUDGET" ;;
esac
if [ -z "$BUDGET" ]; then
  BUDGET="$(python3 -c 'import os; print(os.cpu_count() or 0)' 2>/dev/null)" || BUDGET=""
  case "$BUDGET" in
    ''|*[!0-9]*) BUDGET=1 ;;
    *) [ "$BUDGET" -ge 1 ] || BUDGET=1 ;;
  esac
  # Say so. Failing closed to width 1 is correct, but it costs the whole serial
  # wall-clock this coordinator exists to avoid, and a silent degrade leaves the
  # reader with no way to tell a one-core host from a broken `python3`.
  [ "$BUDGET" -gt 1 ] || \
    printf 'run-parallel: the python3 cpu probe established no usable count — running serially at width 1 (check that python3 resolves)\n' >&2
fi
[ "$BUDGET" -le "$BUDGET_CEILING" ] || BUDGET="$BUDGET_CEILING"

# The nested Python pool forks its own workers, so its slots are reserved OUT of the
# same total rather than added to it — otherwise the budget would bound only the
# top-level shards while the real process count ran to budget + pool width.
POOL_RESERVATION=$((BUDGET - 1))
[ "$POOL_RESERVATION" -ge 1 ] || POOL_RESERVATION=1
[ "$POOL_RESERVATION" -le "$POOL_RESERVATION_CEILING" ] || POOL_RESERVATION="$POOL_RESERVATION_CEILING"

_shard_cost() { # shard-name -> slots this shard occupies
  case "$1" in
    python-pool) printf '%s\n' "$POOL_RESERVATION" ;;
    *) printf '1\n' ;;
  esac
}

# ── Launch bookkeeping + signal handling ─────────────────────────────────────
# Job control gives each background shard its own process group, so a signal can be
# forwarded to the shard AND everything it forked (run.sh, run-module.sh, the pool
# workers) rather than to the shard shell alone.
set -m

# One list of `<pid>:<cost>:<shard>` triples rather than three positionally-coupled
# lists: a shard name is `[a-z0-9-]` by the validation above, so `:` cannot occur in a
# field, and keeping the three values in one record removes the index-alignment the
# separate lists had to maintain by hand.
RUNNING=""
USED_SLOTS=0
LAUNCHING=0
PENDING_SIGNAL=""
SIGNAL_HANDLED=0

_terminate_launched() { # signal
  local sig="$1" rec pid
  for rec in $RUNNING; do
    pid="${rec%%:*}"
    # Signal the GROUP first (the shard plus its descendants), then the leader, so a
    # shell without a usable group still receives it.
    kill -s "$sig" -- "-$pid" 2>/dev/null || :
    kill -s "$sig" "$pid" 2>/dev/null || :
  done
  for rec in $RUNNING; do
    pid="${rec%%:*}"
    kill -s KILL -- "-$pid" 2>/dev/null || :
    kill -s KILL "$pid" 2>/dev/null || :
    # Reap, so the coordinator never exits leaving its children unwaited.
    wait "$pid" 2>/dev/null || :
  done
  RUNNING=""
}

_on_signal() { # signal
  local sig="$1"
  # The fork-to-PID-registration window: a signal delivered between `&` and the
  # assignment of `$!` would otherwise terminate the parent with that child
  # unregistered, unreaped and still running. Park it and replay after registration.
  if [ "$LAUNCHING" -eq 1 ]; then
    PENDING_SIGNAL="$sig"
    return 0
  fi
  [ "$SIGNAL_HANDLED" -eq 0 ] || return 0
  SIGNAL_HANDLED=1
  trap '' HUP INT TERM
  printf 'run-parallel: received %s — terminating and reaping the launched shards\n' "$sig" >&2
  _terminate_launched "$sig"
  exit 1
}

trap '_on_signal HUP' HUP
trap '_on_signal INT' INT
trap '_on_signal TERM' TERM

# Reap every child that has already exited, freeing its slots and recording a non-zero
# status against its shard name. A still-live child is kept in the registry, so a signal
# arriving later still reaches it.
_reap_finished() {
  local rec pid cost name keep=""
  for rec in $RUNNING; do
    pid="${rec%%:*}"; cost="${rec#*:}"; cost="${cost%%:*}"; name="${rec##*:}"
    if kill -0 "$pid" 2>/dev/null; then
      keep="$keep $rec"
    else
      if wait "$pid"; then :; else
        SHARD_RCS="$SHARD_RCS $name=$?"
      fi
      USED_SLOTS=$((USED_SLOTS - cost))
    fi
  done
  RUNNING="$keep"
}

SHARD_RCS=""
LAUNCH_FAILURES=""

printf 'run-parallel: %d shard(s), process budget %d (python-pool reservation %d), run root %s\n' \
  "$SHARD_COUNT" "$BUDGET" "$POOL_RESERVATION" "$RUN_ROOT"

for shard in $SHARDS; do
  cost="$(_shard_cost "$shard")"
  # A shard whose cost exceeds the whole budget still runs — alone. Refusing it would
  # drop coverage, which is the one outcome this coordinator may never trade for speed.
  [ "$cost" -le "$BUDGET" ] || cost="$BUDGET"
  while [ "$USED_SLOTS" -gt 0 ] && [ $((USED_SLOTS + cost)) -gt "$BUDGET" ]; do
    _reap_finished
    [ $((USED_SLOTS + cost)) -le "$BUDGET" ] || sleep 0.05
  done

  shard_tally="$RUN_ROOT/tally/$shard"
  shard_tmp="$RUN_ROOT/tmp/$shard"
  shard_log="$RUN_ROOT/logs/$shard.log"
  if ! mkdir -p "$shard_tally" "$shard_tmp"; then
    LAUNCH_FAILURES="$LAUNCH_FAILURES $shard"
    printf 'run-parallel: shard %s — could not create its private tally/temp directories under %s\n' "$shard" "$RUN_ROOT" >&2
    continue
  fi

  LAUNCHING=1
  # Test seam for the fork-to-registration window (the sibling of
  # module-harness.sh's _devflow_test_pause_before_pid_capture): it holds the run
  # inside the LAUNCHING window so a signal can be delivered there deterministically,
  # and releases as soon as one has been parked. Unset in production, where the
  # window is the few instructions between the `&` and `$!` below.
  if [ -n "${DEVFLOW_TEST_LAUNCH_WINDOW_FILE:-}" ]; then
    printf 'launching\n' > "$DEVFLOW_TEST_LAUNCH_WINDOW_FILE" 2>/dev/null || :
    while [ ! -e "$DEVFLOW_TEST_LAUNCH_WINDOW_FILE.release" ] && [ -z "$PENDING_SIGNAL" ]; do :; done
  fi
  (
    # Each shard is its own process-group leader with a private TMPDIR and tally dir,
    # so sibling shards sharing this checkout cannot collide on either. The nested
    # pool width is exported only to the shard that owns the reservation.
    export TMPDIR="$shard_tmp"
    export DEVFLOW_SHARD_TALLY_DIR="$shard_tally"
    export DEVFLOW_PARALLEL_SUITE_ACTIVE=1
    if [ "$shard" = python-pool ]; then
      export DEVFLOW_POOL_WIDTH="$POOL_RESERVATION"
    fi
    exec bash "$DISPATCHER" "$shard" > "$shard_log" 2>&1
  ) &
  launched_pid=$!
  RUNNING="$RUNNING $launched_pid:$cost:$shard"
  USED_SLOTS=$((USED_SLOTS + cost))
  LAUNCHING=0
  [ -z "$PENDING_SIGNAL" ] || _on_signal "$PENDING_SIGNAL"
  printf 'run-parallel: launched shard %s (pid %s, %s slot(s))\n' "$shard" "$launched_pid" "$cost"
done

# Wait for the COMPLETE launched population PID by PID (portable: no `wait -n`), so
# aggregation never reads a tally a shard is still writing.
for rec in $RUNNING; do
  pid="${rec%%:*}"; name="${rec##*:}"
  if wait "$pid"; then :; else
    SHARD_RCS="$SHARD_RCS $name=$?"
  fi
done
RUNNING=""

# ── Aggregate ────────────────────────────────────────────────────────────────
# Explicit per-shard tally paths derived from the population this run launched —
# never `--scan`, whose parent directory would also admit a stale sibling run's
# tally and let it satisfy this invocation's --expect floor.
# An ARRAY, not a space-joined string: a checkout path containing a space (a WSL
# `/mnt/c/Users/First Last/...` tree is a supported tier) would word-split every entry,
# turning N real paths into more than N bogus ones — which satisfies `--expect`'s
# missing-shard floor from garbage and leaves only the unreadable-tally guard between
# the run and a vacuous pass.
TALLY_ARGS=()
EXPECTED=0
MISSING=""
for shard in $SHARDS; do
  case " $LAUNCH_FAILURES " in *" $shard "*) continue ;; esac
  EXPECTED=$((EXPECTED + 1))
  if [ -f "$RUN_ROOT/tally/$shard/summary" ]; then
    TALLY_ARGS+=("$RUN_ROOT/tally/$shard")
  else
    MISSING="$MISSING $shard"
  fi
done

AGGREGATE_RC=0
if [ -n "$LAUNCH_FAILURES" ]; then
  printf 'run-parallel: shard(s) failed to launch:%s\n' "$LAUNCH_FAILURES" >&2
  AGGREGATE_RC=1
fi
if [ -n "$MISSING" ]; then
  printf 'run-parallel: shard(s) produced no tally:%s — see the retained logs under %s\n' \
    "$MISSING" "$RUN_ROOT/logs" >&2
  AGGREGATE_RC=1
fi
if [ -n "$SHARD_RCS" ]; then
  # This must SET the failure, not merely report it. A shard killed AFTER
  # shard-tally.py wrote its tally but BEFORE run-shard.sh returned (the OOM killer
  # on a saturated host is the reachable case) leaves a complete, clean-looking tally
  # beside a non-zero status: `MISSING` never fires, `combine` sums a green tally, and
  # a printed-but-inert observation would let the run exit 0 while announcing that a
  # shard did not complete.
  printf 'run-parallel: shard process(es) exited non-zero:%s — refusing a clean aggregate over a shard that did not complete\n' "$SHARD_RCS" >&2
  AGGREGATE_RC=1
fi

# `--expect` is the missing-shard floor: it is the count this run actually launched,
# so a shard that died before writing its tally cannot be silently dropped.
if ! python3 "$TALLY_HELPER" combine "${TALLY_ARGS[@]}" --expect "$EXPECTED" --detail-cap "$DETAIL_CAP"; then
  AGGREGATE_RC=1
fi

printf '\n'
printf 'run-parallel: shard roster:%s\n' "$(printf ' %s' $SHARDS)"
printf 'run-parallel: retained logs: %s\n' "$RUN_ROOT/logs"
if [ "$AGGREGATE_RC" -eq 0 ]; then
  printf 'run-parallel: aggregate CLEAN\n'
else
  printf 'run-parallel: aggregate FAILED — read the retained logs above rather than re-running\n' >&2
fi
exit "$AGGREGATE_RC"
