# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable focused module for the in-run parallel full-suite coordinator
# (`lib/test/run-parallel.sh`, issue #1086).
#
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first. Modules may not self-skip.
#
# Everything here drives the coordinator against SYNTHETIC shard dispatchers planted
# in fixture trees. The real shard population is never launched from inside this
# module: a shard runs modules, so a real-population invocation here would fork a
# whole second suite underneath the shard running this file. That reentrancy is
# itself asserted below (the coordinator refuses it by name), and the serial-vs-
# parallel comparison over the real population deliberately lives outside the
# registered module set.
#
# `shard-tally.py` is NOT mocked — the fixture dispatchers write their tallies
# through the real extractor, so the aggregation contract under test is the shipped
# one.

PSR_COORD="$LIB/test/run-parallel.sh"
PSR_TALLY="$LIB/test/shard-tally.py"
PSR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devflow-psr.XXXXXX")"

# ── fixture builders ─────────────────────────────────────────────────────────
# A fixture tree is a miniature checkout: the coordinator anchors its REPO_ROOT to
# `<script dir>/../..`, so copying it into <tree>/lib/test gives that tree its own
# run root, and nothing here can write into the real checkout.
psr_make_tree() { # -> prints a fresh fixture tree root
  local tree
  tree="$(mktemp -d "$PSR_ROOT/tree.XXXXXX")"
  mkdir -p "$tree/lib/test"
  cp "$PSR_COORD" "$tree/lib/test/run-parallel.sh"
  cp "$PSR_TALLY" "$tree/lib/test/shard-tally.py"
  chmod +x "$tree/lib/test/run-parallel.sh"
  printf '%s\n' "$tree"
}

# A dispatcher that answers --list-shards from SYN_SHARDS, records a start/end
# timestamp plus its inherited TMPDIR and pool width, and writes a real tally.
psr_plant_dispatcher() { # tree
  local tree="$1"
  cat > "$tree/dispatch.sh" <<'PSR_EOF'
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
case "${1-}" in
  --list-shards) printf '%s\n' ${SYN_SHARDS:-alpha beta python-pool}; exit 0 ;;
esac
S="$1"
D="${DEVFLOW_SHARD_TALLY_DIR:?}"
mkdir -p "$D"
if [ -n "${SYN_TRACE:-}" ]; then
  # Keyword only, no timestamp: `date +%s%N` is GNU-only (BSD/macOS emit a literal N),
  # and the overlap reader below counts start/end keywords, never a clock value.
  printf 'start %s\n' "$S" >> "$SYN_TRACE"
  printf 'env %s tmpdir=%s poolwidth=%s\n' "$S" "${TMPDIR:-}" "${DEVFLOW_POOL_WIDTH:-}" >> "$SYN_TRACE"
fi
sleep "${SYN_SLEEP:-0.4}"
[ -z "${SYN_TRACE:-}" ] || printf 'end %s\n' "$S" >> "$SYN_TRACE"
LOG="$D/log.txt"
printf 'assertion noise that must not be replayed\n2 passed, 0 failed\n' > "$LOG"
python3 "$HERE/lib/test/shard-tally.py" extract --shard "$S" --tier monolith \
  --log "$LOG" --rc 0 --out "$D" >/dev/null
PSR_EOF
  chmod +x "$tree/dispatch.sh"
}

# Count how many shards were live at once, from the trace's start/end ordering.
# Derived with bash builtins: the value decides an asserted operand, so it must not
# depend on a tool the project's preflight does not guarantee (CLAUDE.md guard-class 2).
psr_max_overlap() { # trace-file
  local line kind live=0 max=0
  while IFS= read -r line || [ -n "$line" ]; do
    kind="${line%% *}"
    case "$kind" in
      start) live=$((live + 1)); [ "$live" -le "$max" ] || max="$live" ;;
      end) live=$((live - 1)) ;;
      *) : ;;
    esac
  done < "$1"
  printf '%s\n' "$max"
}

# Print the recorded pool width for one shard ("(absent)" when the shard inherited none).
psr_pool_width_of() { # trace-file shard
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "env $2 "*)
        line="${line##*poolwidth=}"
        [ -n "$line" ] || line="(absent)"
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done < "$1"
  printf '(no-record)\n'
}

# Count lines in a file with builtins alone (same guard-class-2 reason as above).
psr_count_matching() { # file prefix
  local line n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2"*) n=$((n + 1)) ;; esac
  done < "$1"
  printf '%s\n' "$n"
}

# ── population, overlap, budget, and the nested-pool reservation ──────────────
PSR_T1="$(psr_make_tree)"; psr_plant_dispatcher "$PSR_T1"

PSR_TRACE="$PSR_T1/trace-8"
( cd "$PSR_T1" && SYN_TRACE="$PSR_TRACE" DEVFLOW_SHARD_DISPATCHER="$PSR_T1/dispatch.sh" \
    DEVFLOW_SUITE_PROCESS_BUDGET=8 bash lib/test/run-parallel.sh > "$PSR_T1/out-8" 2>&1 )
assert_eq "psr population: budget 8 → clean aggregate, exit 0" "0" "$?"
assert_eq "psr population: budget 8 → all three returned shards overlap" "3" \
  "$(psr_max_overlap "$PSR_TRACE")"
assert_eq "psr population: the launch population is the dispatcher's returned list, not a copy" "alpha beta python-pool" \
  "$(cd "$PSR_T1" && bash dispatch.sh --list-shards | { PSR_ACC=""; while IFS= read -r psr_s || [ -n "$psr_s" ]; do
       [ -z "$psr_s" ] || PSR_ACC="${PSR_ACC:+$PSR_ACC }$psr_s"; done; printf '%s\n' "$PSR_ACC"; })"
assert_eq "psr population: the aggregate sums every shard's tally" "yes" \
  "$(case "$(cat "$PSR_T1/out-8")" in *"6 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"

# The nested Python pool's width is a RESERVATION out of the same total, exported to
# the shard that owns it and to no other — a sibling that also read a width would
# multiply the process count past the budget the scheduler thinks it is enforcing.
assert_eq "psr population: python-pool receives the nested-pool reservation" "4" \
  "$(psr_pool_width_of "$PSR_TRACE" python-pool)"
assert_eq "psr population: a normal shard receives no pool reservation" "(absent)" \
  "$(psr_pool_width_of "$PSR_TRACE" alpha)"
# Private per-shard TMPDIRs are what make one shared checkout safe for concurrent
# shards; two shards handed the same temp root would collide on every mktemp name.
assert_eq "psr population: each shard is handed its own private TMPDIR" "yes" \
  "$(PSR_TA=""; PSR_TB=""
     while IFS= read -r l || [ -n "$l" ]; do
       case "$l" in
         "env alpha "*) PSR_TA="${l#*tmpdir=}"; PSR_TA="${PSR_TA%% *}" ;;
         "env beta "*) PSR_TB="${l#*tmpdir=}"; PSR_TB="${PSR_TB%% *}" ;;
       esac
     done < "$PSR_TRACE"
     { [ -n "$PSR_TA" ] && [ -n "$PSR_TB" ] && [ "$PSR_TA" != "$PSR_TB" ]; } && echo yes || echo no)"
assert_eq "psr population: the run announces the budget and the reservation it resolved" "yes" \
  "$(case "$(cat "$PSR_T1/out-8")" in *"process budget 8 (python-pool reservation 4)"*) echo yes ;; *) echo no ;; esac)"

PSR_TRACE2="$PSR_T1/trace-2"
( cd "$PSR_T1" && SYN_TRACE="$PSR_TRACE2" DEVFLOW_SHARD_DISPATCHER="$PSR_T1/dispatch.sh" \
    SYN_SHARDS="alpha beta" DEVFLOW_SUITE_PROCESS_BUDGET=2 bash lib/test/run-parallel.sh >/dev/null 2>&1 )
assert_eq "psr population: budget 2 → the returned shards still overlap" "2" \
  "$(psr_max_overlap "$PSR_TRACE2")"

# Width one is the fail-closed floor: serial, and COMPLETE — never a reduced population.
PSR_TRACE1="$PSR_T1/trace-1"
( cd "$PSR_T1" && SYN_TRACE="$PSR_TRACE1" DEVFLOW_SHARD_DISPATCHER="$PSR_T1/dispatch.sh" \
    DEVFLOW_SUITE_PROCESS_BUDGET=1 bash lib/test/run-parallel.sh > "$PSR_T1/out-1" 2>&1 )
assert_eq "psr population: budget 1 → exit 0" "0" "$?"
assert_eq "psr population: budget 1 → strictly serial (never two shards live at once)" "1" \
  "$(psr_max_overlap "$PSR_TRACE1")"
assert_eq "psr population: budget 1 → still complete (every shard ran)" "3" \
  "$(psr_count_matching "$PSR_TRACE1" "start ")"
assert_eq "psr population: budget 1 → the aggregate is the same total as budget 8" "yes" \
  "$(case "$(cat "$PSR_T1/out-1")" in *"6 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"

# The budget is a decided value, so a non-positive-integer override must not be
# honoured silently and an unestablished probe must fail closed rather than open.
for psr_bad in "" "0" "-3" "two" "3.5"; do
  PSR_OUT="$(cd "$PSR_T1" && DEVFLOW_SHARD_DISPATCHER="$PSR_T1/dispatch.sh" SYN_SHARDS=alpha \
      DEVFLOW_SUITE_PROCESS_BUDGET="$psr_bad" bash lib/test/run-parallel.sh 2>&1)"
  assert_eq "psr population: override '$psr_bad' is rejected, the probe decides, and the run still completes" "yes" \
    "$(case "$PSR_OUT" in *"2 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
done
PSR_OUT="$(cd "$PSR_T1" && DEVFLOW_SHARD_DISPATCHER="$PSR_T1/dispatch.sh" SYN_SHARDS=alpha \
    DEVFLOW_SUITE_PROCESS_BUDGET=999 bash lib/test/run-parallel.sh 2>&1)"
assert_eq "psr population: the budget is capped at eight however large the override" "yes" \
  "$(case "$PSR_OUT" in *"process budget 8 "*) echo yes ;; *) echo no ;; esac)"

# ── isolation: a stale sibling run's tally never satisfies this invocation ────
PSR_T2="$(psr_make_tree)"; psr_plant_dispatcher "$PSR_T2"
( cd "$PSR_T2" && DEVFLOW_SHARD_DISPATCHER="$PSR_T2/dispatch.sh" SYN_SHARDS="alpha beta" \
    SYN_SLEEP=0.05 bash lib/test/run-parallel.sh >/dev/null 2>&1 )
# The second run must allocate a DIFFERENT root, and must aggregate only its own
# tallies — a `--scan` of the shared parent would have admitted the first run's.
( cd "$PSR_T2" && DEVFLOW_SHARD_DISPATCHER="$PSR_T2/dispatch.sh" SYN_SHARDS="alpha beta" \
    SYN_SLEEP=0.05 bash lib/test/run-parallel.sh > "$PSR_T2/out-2" 2>&1 )
# Counted with a glob, not `ls | grep`: a glob cannot be defeated by a name `ls`
# renders oddly, and the count decides an asserted operand.
assert_eq "psr isolation: consecutive runs allocate distinct run roots" "2" \
  "$(cd "$PSR_T2" && PSR_N=0; for psr_d in .prflow/tmp/parallel-suite/run-*; do
       [ -d "$psr_d" ] && PSR_N=$((PSR_N + 1)); done; printf '%s\n' "$PSR_N")"
assert_eq "psr isolation: the second run aggregates only its own two shards" "yes" \
  "$(case "$(cat "$PSR_T2/out-2")" in *"combine: 2 shard(s): alpha, beta"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr isolation: the second run's total is its own, not the pair of runs'" "yes" \
  "$(case "$(cat "$PSR_T2/out-2")" in *"4 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
# A stale sibling planted with the CURRENT run's shard names still must not count.
mkdir -p "$PSR_T2/.prflow/tmp/parallel-suite/run-stale/tally/gamma"
printf 'shard\tgamma\npassed\t99\nfailed\t0\nskipped\t0\nrc\t0\n' \
  > "$PSR_T2/.prflow/tmp/parallel-suite/run-stale/tally/gamma/summary"
: > "$PSR_T2/.prflow/tmp/parallel-suite/run-stale/tally/gamma/skips"
: > "$PSR_T2/.prflow/tmp/parallel-suite/run-stale/tally/gamma/names"
( cd "$PSR_T2" && DEVFLOW_SHARD_DISPATCHER="$PSR_T2/dispatch.sh" SYN_SHARDS="alpha beta" \
    SYN_SLEEP=0.05 bash lib/test/run-parallel.sh > "$PSR_T2/out-3" 2>&1 )
assert_eq "psr isolation: a planted stale tally directory does not reach the aggregate" "yes" \
  "$(case "$(cat "$PSR_T2/out-3")" in *"4 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr isolation: the stale shard name is absent from the roster line" "yes" \
  "$(case "$(cat "$PSR_T2/out-3")" in *"combine: 2 shard(s): alpha, beta"*) echo yes ;; *) echo no ;; esac)"

# ── failure contract ─────────────────────────────────────────────────────────
PSR_T3="$(psr_make_tree)"
cat > "$PSR_T3/dispatch.sh" <<'PSR_EOF'
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
case "${1-}" in
  --list-shards)
    case "${SYN_MODE:-}" in
      empty) exit 0 ;;
      badname) printf '%s\n' 'Bad/Name'; exit 0 ;;
      listfail) exit 3 ;;
      dup) printf '%s\n' alpha beta alpha ;;
      *) printf '%s\n' alpha beta ;;
    esac
    exit 0 ;;
esac
S="$1"; D="${DEVFLOW_SHARD_TALLY_DIR:?}"; mkdir -p "$D"
case "${SYN_MODE:-}" in
  crash) [ "$S" = beta ] && { printf 'shard crashed\n' >&2; exit 7; } ;;
  nonzero) [ "$S" = beta ] && { printf '1 passed, 1 failed\n' > "$D/log.txt"
      python3 "$HERE/lib/test/shard-tally.py" extract --shard "$S" --tier monolith \
        --log "$D/log.txt" --rc 1 --out "$D" >/dev/null; exit 1; } ;;
  malformed) [ "$S" = beta ] && { printf 'shard\tbeta\npassed\tnot-a-number\n' > "$D/summary"; exit 0; } ;;
  skipdis) [ "$S" = beta ] && {
      printf 'shard\tbeta\npassed\t1\nfailed\t0\nskipped\t0\nrc\t0\n' > "$D/summary"
      printf 'a skip nothing announced\n' > "$D/skips"; : > "$D/names"; exit 0; } ;;
  killed-after-tally) [ "$S" = beta ] && {
      # The OOM-killer shape: the tally is complete and CLEAN, and the process then dies
      # non-zero. Nothing in the tally records the death, so only the coordinator's own
      # reading of the child's exit status can catch it.
      printf '1 passed, 0 failed\n' > "$D/log.txt"
      python3 "$HERE/lib/test/shard-tally.py" extract --shard "$S" --tier monolith \
        --log "$D/log.txt" --rc 0 --out "$D" >/dev/null
      exit 9; } ;;
esac
printf '1 passed, 0 failed\n' > "$D/log.txt"
python3 "$HERE/lib/test/shard-tally.py" extract --shard "$S" --tier monolith \
  --log "$D/log.txt" --rc 0 --out "$D" >/dev/null
PSR_EOF
chmod +x "$PSR_T3/dispatch.sh"

psr_fail_case() { # mode -> prints "<rc>|<combined output>"
  local mode="$1" out rc
  out="$(cd "$PSR_T3" && SYN_MODE="$mode" DEVFLOW_SHARD_DISPATCHER="$PSR_T3/dispatch.sh" \
    bash lib/test/run-parallel.sh 2>&1)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

PSR_FC="$(psr_fail_case empty)"
assert_eq "psr failure: an empty shard population is refused, not reported clean" "yes" \
  "$(case "$PSR_FC" in 2\|*"empty population"*) echo yes ;; *) echo no ;; esac)"
PSR_FC="$(psr_fail_case badname)"
assert_eq "psr failure: a malformed shard name is refused by name" "yes" \
  "$(case "$PSR_FC" in 2\|*"malformed shard name"*"Bad/Name"*) echo yes ;; *) echo no ;; esac)"
PSR_FC="$(psr_fail_case listfail)"
assert_eq "psr failure: a dispatcher that cannot list its shards is refused by name" "yes" \
  "$(case "$PSR_FC" in 2\|*"failed to list its shards"*) echo yes ;; *) echo no ;; esac)"
PSR_FC="$(psr_fail_case crash)"
assert_eq "psr failure: a crashed shard yields a nonzero aggregate" "yes" \
  "$(case "$PSR_FC" in 1\|*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr failure: a crashed shard is named, with its exit status" "yes" \
  "$(case "$PSR_FC" in *"exited non-zero"*"beta=7"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr failure: a shard that wrote no tally is named as such" "yes" \
  "$(case "$PSR_FC" in *"produced no tally"*beta*) echo yes ;; *) echo no ;; esac)"
PSR_FC="$(psr_fail_case nonzero)"
assert_eq "psr failure: a shard reporting a failed assertion fails the aggregate" "yes" \
  "$(case "$PSR_FC" in 1\|*"1 failed"*) echo yes ;; *) echo no ;; esac)"
PSR_FC="$(psr_fail_case malformed)"
assert_eq "psr failure: a malformed tally fails closed with a PROBLEM naming it" "yes" \
  "$(case "$PSR_FC" in 1\|*PROBLEM*) echo yes ;; *) echo no ;; esac)"
PSR_FC="$(psr_fail_case skipdis)"
assert_eq "psr failure: a skip-detail disagreement fails the aggregate" "yes" \
  "$(case "$PSR_FC" in 1\|*"disagrees with"*) echo yes ;; *) echo no ;; esac)"
# A shard killed AFTER writing a clean tally: the aggregate sums green and no shard is
# missing, so the child's exit status is the ONLY surviving signal. A coordinator that
# merely printed it would exit 0 while announcing that a shard did not complete.
PSR_FC="$(psr_fail_case killed-after-tally)"
assert_eq "psr failure: a shard killed after writing a clean tally still fails the aggregate" "1" \
  "${PSR_FC%%|*}"
assert_eq "psr failure: that shard's non-zero exit is named as the refusal reason" "yes" \
  "$(case "$PSR_FC" in *"exited non-zero"*"beta=9"*"refusing a clean aggregate"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr failure: the killed shard's tally still summed green (so the exit status was the only signal)" "yes" \
  "$(case "$PSR_FC" in *"2 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
# A duplicated shard name would put two processes in ONE tally directory, double-count it
# through --expect, and silently drop whichever shard the duplicate displaced.
PSR_FC="$(psr_fail_case dup)"
assert_eq "psr failure: a duplicated shard name is refused before anything is launched" "yes" \
  "$(case "$PSR_FC" in 2\|*"duplicate shard name"*alpha*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr failure: the duplicate refusal launches no shard at all" "yes" \
  "$(case "$PSR_FC" in *"launched shard"*) echo no ;; *) echo yes ;; esac)"
# Launch failure: a shard whose private tally/temp directories cannot be created. The
# run root is fresh by construction, so the only honest way to reach this arm is to
# revoke write permission on it WHILE the coordinator is mid-launch — which the launch
# window seam makes deterministic: the first shard is held there, the test revokes, and
# the second shard's directory creation then fails.
PSR_T3B="$(psr_make_tree)"; psr_plant_dispatcher "$PSR_T3B"
PSR_LF_WIN="$PSR_T3B/lf-win"
( cd "$PSR_T3B" || exit 1
  export SYN_SHARDS="alpha beta" SYN_SLEEP=0.05 \
    DEVFLOW_TEST_LAUNCH_WINDOW_FILE="$PSR_LF_WIN" \
    DEVFLOW_SHARD_DISPATCHER="$PSR_T3B/dispatch.sh"
  exec bash lib/test/run-parallel.sh > "$PSR_T3B/lf-out" 2>&1 ) &
PSR_LF_PID=$!
while [ ! -e "$PSR_LF_WIN" ]; do sleep 0.01; done
PSR_LF_ROOT="$(cd "$PSR_T3B" && PSR_LAST=""; for psr_d in .prflow/tmp/parallel-suite/run-*; do
  [ -d "$psr_d" ] && PSR_LAST="$psr_d"; done; printf '%s\n' "$PSR_LAST")"
chmod a-w "$PSR_T3B/$PSR_LF_ROOT/tally" "$PSR_T3B/$PSR_LF_ROOT/tmp"
: > "$PSR_LF_WIN.release"
wait "$PSR_LF_PID"
assert_eq "psr failure: a launch failure yields a nonzero aggregate" "1" "$?"
chmod u+w "$PSR_T3B/$PSR_LF_ROOT/tally" "$PSR_T3B/$PSR_LF_ROOT/tmp"
PSR_LF_OUT="$(cat "$PSR_T3B/lf-out")"
assert_eq "psr failure: a shard whose private directories cannot be created is named" "yes" \
  "$(case "$PSR_LF_OUT" in *"could not create its private tally/temp directories"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr failure: the un-launched shard is named in the launch-failure list" "yes" \
  "$(case "$PSR_LF_OUT" in *"failed to launch"*beta*) echo yes ;; *) echo no ;; esac)"

# A checkout path containing a space: the tally paths must reach `combine` as N distinct
# arguments, not as word-split fragments that satisfy the --expect floor from garbage.
PSR_T3C="$(mktemp -d "$PSR_ROOT/with space.XXXXXX")"
mkdir -p "$PSR_T3C/lib/test"
cp "$PSR_COORD" "$PSR_T3C/lib/test/run-parallel.sh"
cp "$PSR_TALLY" "$PSR_T3C/lib/test/shard-tally.py"
chmod +x "$PSR_T3C/lib/test/run-parallel.sh"
psr_plant_dispatcher "$PSR_T3C"
PSR_SPACE_OUT="$(cd "$PSR_T3C" && SYN_SHARDS="alpha beta" SYN_SLEEP=0.05 \
  DEVFLOW_SHARD_DISPATCHER="$PSR_T3C/dispatch.sh" bash lib/test/run-parallel.sh 2>&1)"
assert_eq "psr failure: a checkout path containing a space still aggregates cleanly" "yes" \
  "$(case "$PSR_SPACE_OUT" in *"4 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr failure: a space in the path produces no split/unreadable tally PROBLEM" "yes" \
  "$(case "$PSR_SPACE_OUT" in *PROBLEM*) echo no ;; *) echo yes ;; esac)"

# ── reentrancy ───────────────────────────────────────────────────────────────
PSR_T4="$(psr_make_tree)"
cat > "$PSR_T4/dispatch.sh" <<'PSR_EOF'
#!/usr/bin/env bash
set -u
case "${1-}" in --list-shards) printf '%s\n' alpha; exit 0 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd -P)"
cd "$HERE" || exit 9
env -u DEVFLOW_SHARD_DISPATCHER bash lib/test/run-parallel.sh
PSR_EOF
chmod +x "$PSR_T4/dispatch.sh"
( cd "$PSR_T4" && DEVFLOW_SHARD_DISPATCHER="$PSR_T4/dispatch.sh" bash lib/test/run-parallel.sh \
    > "$PSR_T4/out" 2>&1 )
assert_eq "psr reentrancy: a real-population invocation from inside a shard is refused by name" "yes" \
  "$(case "$(cat "$PSR_T4"/.prflow/tmp/parallel-suite/run-*/logs/alpha.log)" in *reentrancy*) echo yes ;; *) echo no ;; esac)"

# ── signal handling: before and after PID registration ───────────────────────
PSR_T5="$(psr_make_tree)"
cat > "$PSR_T5/dispatch.sh" <<'PSR_EOF'
#!/usr/bin/env bash
set -u
case "${1-}" in --list-shards) printf '%s\n' alpha beta; exit 0 ;; esac
# A resistant child: it ignores the polite signals, so only the coordinator's
# escalation-and-reap can clear it.
trap '' HUP INT TERM
printf '%s\n' "$$" >> "${SYN_PIDFILE:?}"
sleep 30
PSR_EOF
chmod +x "$PSR_T5/dispatch.sh"

psr_signal_case() { # signal window(pre|post) -> prints "<rc>|<alive-count>|<acknowledged>"
  local sig="$1" window="$2" pidfile winfile coord rc alive=0 p ack=no
  pidfile="$PSR_T5/pids-$sig-$window"; winfile="$PSR_T5/win-$sig-$window"
  : > "$pidfile"; rm -f "$winfile" "$winfile.release"
  # `exec` is load-bearing: without it the backgrounded SUBSHELL is what `$!` names, so
  # the signal would reach that shell (dying 128+sig) and leave the coordinator running
  # as an orphan — the test would then measure the subshell's default disposition rather
  # than the coordinator's handler.
  if [ "$window" = pre ]; then
    ( cd "$PSR_T5" || exit 1
      export SYN_PIDFILE="$pidfile" DEVFLOW_TEST_LAUNCH_WINDOW_FILE="$winfile" \
        DEVFLOW_SHARD_DISPATCHER="$PSR_T5/dispatch.sh"
      exec bash lib/test/run-parallel.sh > "$PSR_T5/out-$sig-$window" 2>&1 ) &
    coord=$!
    while [ ! -e "$winfile" ]; do sleep 0.01; done
  else
    ( cd "$PSR_T5" || exit 1
      export SYN_PIDFILE="$pidfile" DEVFLOW_SHARD_DISPATCHER="$PSR_T5/dispatch.sh"
      exec bash lib/test/run-parallel.sh > "$PSR_T5/out-$sig-$window" 2>&1 ) &
    coord=$!
    # Wait until both shard children have published their PIDs, i.e. both are
    # registered. Counted with builtins, never a PATH tool (guard-class 2).
    while [ "$(psr_count_matching "$pidfile" "")" -lt 2 ]; do sleep 0.05; done
  fi
  kill -s "$sig" "$coord" 2>/dev/null || :
  wait "$coord"; rc=$?
  # Give the escalation a moment, then count survivors.
  sleep 0.5
  while IFS= read -r p || [ -n "$p" ]; do
    [ -z "$p" ] || { kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); }
  done < "$pidfile"
  while IFS= read -r p || [ -n "$p" ]; do
    case "$p" in *"received $sig"*) ack=yes ;; esac
  done < "$PSR_T5/out-$sig-$window"
  printf '%s|%s|%s' "$rc" "$alive" "$ack"
}

for psr_sig in HUP INT TERM; do
  PSR_SC="$(psr_signal_case "$psr_sig" post)"
  assert_eq "psr signal: $psr_sig after registration → exits 1, acknowledges the signal, and every launched shard is reaped" \
    "1|0|yes" "$PSR_SC"
  # A signal delivered inside the LAUNCH WINDOW must be PARKED and REPLAYED, not dropped:
  # a coordinator that swallowed it would run the population to completion and exit 0,
  # which is what this comparison refuses (verified by mutation — deleting the replay
  # line turns this assertion RED). Scope stated honestly: the seam holds the run just
  # BEFORE the fork, so no child is registered yet and the survivor count is not a
  # discriminator here; this proves the park-and-replay path, not the narrower
  # between-`&`-and-`$!` instant, which no portable seam can hold open.
  PSR_SC="$(psr_signal_case "$psr_sig" pre)"
  assert_eq "psr signal: $psr_sig parked in the launch window is replayed, not swallowed" \
    "1|0|yes" "$PSR_SC"
done

# ── output contract: clean-run suppression, the detail cap, retained logs ─────
PSR_T6="$(psr_make_tree)"
cat > "$PSR_T6/dispatch.sh" <<'PSR_EOF'
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
case "${1-}" in --list-shards) printf '%s\n' alpha; exit 0 ;; esac
S="$1"; D="${DEVFLOW_SHARD_TALLY_DIR:?}"; mkdir -p "$D"
LOG="$D/log.txt"
: > "$LOG"
i=0
while [ "$i" -lt 40 ]; do printf 'PASS  assertion-noise-%s\n' "$i" >> "$LOG"; i=$((i + 1)); done
if [ -n "${SYN_BULK:-}" ]; then
  printf '0 passed, 25 failed, 25 skipped\n' >> "$LOG"
  i=0; while [ "$i" -lt 25 ]; do printf '  SKIP  synthetic-skip-%s\n' "$i" >> "$LOG"; i=$((i + 1)); done
  printf 'Failure recap:\n' >> "$LOG"
  i=0; while [ "$i" -lt 25 ]; do printf '  - synthetic-failure-%s\n' "$i" >> "$LOG"; i=$((i + 1)); done
  # Echo the captured log the way the real dispatcher does, so the coordinator's
  # per-shard capture holds the complete detail the cap elides from the aggregate.
  cat "$LOG"
  python3 "$HERE/lib/test/shard-tally.py" extract --shard "$S" --tier monolith --log "$LOG" --rc 1 --out "$D" >/dev/null
  exit 1
fi
printf '3 passed, 0 failed\n' >> "$LOG"
cat "$LOG"
python3 "$HERE/lib/test/shard-tally.py" extract --shard "$S" --tier monolith --log "$LOG" --rc 0 --out "$D" >/dev/null
PSR_EOF
chmod +x "$PSR_T6/dispatch.sh"

PSR_CLEAN="$(cd "$PSR_T6" && DEVFLOW_SHARD_DISPATCHER="$PSR_T6/dispatch.sh" bash lib/test/run-parallel.sh 2>&1)"
assert_eq "psr output: a clean run does not replay the shard's assertion log" "yes" \
  "$(case "$PSR_CLEAN" in *assertion-noise-*) echo no ;; *) echo yes ;; esac)"
assert_eq "psr output: a clean run states the combined result" "yes" \
  "$(case "$PSR_CLEAN" in *"3 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr output: a clean run emits the launch lifecycle breadcrumb" "yes" \
  "$(case "$PSR_CLEAN" in *"launched shard alpha"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr output: a clean run names the shard roster" "yes" \
  "$(case "$PSR_CLEAN" in *"shard roster: alpha"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr output: a clean run names the retained-log root" "yes" \
  "$(case "$PSR_CLEAN" in *"retained logs: "*/logs*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr output: a clean run says so" "yes" \
  "$(case "$PSR_CLEAN" in *"aggregate CLEAN"*) echo yes ;; *) echo no ;; esac)"

PSR_BULK="$(cd "$PSR_T6" && SYN_BULK=1 DEVFLOW_SHARD_DISPATCHER="$PSR_T6/dispatch.sh" bash lib/test/run-parallel.sh 2>&1)"
PSR_SKIP_LINES=0; PSR_FAIL_LINES=0
while IFS= read -r psr_line || [ -n "$psr_line" ]; do
  case "$psr_line" in
    "  SKIP  synthetic-skip-"*) PSR_SKIP_LINES=$((PSR_SKIP_LINES + 1)) ;;
    "  - synthetic-failure-"*) PSR_FAIL_LINES=$((PSR_FAIL_LINES + 1)) ;;
  esac
done <<PSR_BULK_EOF
$PSR_BULK
PSR_BULK_EOF
assert_eq "psr output: 25 skip entries render 20 detail lines (the enforcement cap)" "20" "$PSR_SKIP_LINES"
assert_eq "psr output: 25 failure entries render 20 detail lines (the enforcement cap)" "20" "$PSR_FAIL_LINES"
assert_eq "psr output: the capped skip class announces the omitted count" "yes" \
  "$(case "$PSR_BULK" in *"SKIP  (5 omitted"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr output: the capped failure class announces the omitted count" "yes" \
  "$(case "$PSR_BULK" in *"- (5 omitted"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr output: the announced tally is the FULL count, not the capped one" "yes" \
  "$(case "$PSR_BULK" in *"0 passed, 25 failed, 25 skipped"*) echo yes ;; *) echo no ;; esac)"
# The cap bounds what is RENDERED, never what is RETAINED.
PSR_BULK_LOG="$(cd "$PSR_T6" && PSR_LAST=""; for psr_d in .prflow/tmp/parallel-suite/run-*; do
  [ -d "$psr_d" ] && PSR_LAST="$psr_d"; done; printf '%s\n' "$PSR_LAST")/logs/alpha.log"
assert_eq "psr output: the complete synthetic log stays readable under the retained run root" "yes" \
  "$(cd "$PSR_T6" && [ -r "$PSR_BULK_LOG" ] && echo yes || echo no)"
assert_eq "psr output: every one of the 25 skip entries survives in the retained log" "25" \
  "$(cd "$PSR_T6" && psr_count_matching "$PSR_BULK_LOG" "  SKIP  synthetic-skip-")"

# ── matcher shape: the bare cloud token, and the local DEVFLOW_BASH boundary ──
assert_eq "psr shape: the coordinator is executable" "yes" \
  "$([ -x "$PSR_COORD" ] && echo yes || echo no)"
assert_eq "psr shape: the coordinator carries an env-bash shebang (so the bare token runs)" "#!/usr/bin/env bash" \
  "$(IFS= read -r psr_l < "$PSR_COORD"; printf '%s\n' "$psr_l")"
PSR_T7="$(psr_make_tree)"; psr_plant_dispatcher "$PSR_T7"
# The cloud actor's whole command is the leading token and nothing else: caller-side
# assignment, redirect, pipeline, interpreter prefix and background syntax are each a
# shape the cloud matcher refuses even when the head is granted, so none is spelled here.
PSR_BARE="$(cd "$PSR_T7" && SYN_SHARDS=alpha SYN_SLEEP=0.05 \
  DEVFLOW_SHARD_DISPATCHER="$PSR_T7/dispatch.sh" ./lib/test/run-parallel.sh 2>&1)"
assert_eq "psr shape: the bare leading-token invocation is the complete command shape" "yes" \
  "$(case "$PSR_BARE" in *"2 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr shape: an argument is refused (the bare form takes none)" "yes" \
  "$(cd "$PSR_T7" && ./lib/test/run-parallel.sh --shards 2>&1 | grep -c 'unknown argument' >/dev/null && echo yes || echo no)"
# The local tier reaches the same coordinator through the documented DEVFLOW_BASH
# selection boundary. WSL bash, Git Bash and MSYS2 bash differ only in WHICH bash the
# operator points at, so each is exercised as a distinctly-named selector.
for psr_flavor in wsl-bash git-bash msys2-bash; do
  printf '#!/usr/bin/env bash\nexec bash "$@"\n' > "$PSR_T7/$psr_flavor"
  chmod +x "$PSR_T7/$psr_flavor"
  PSR_SEL_OUT="$(cd "$PSR_T7" && SYN_SHARDS=alpha SYN_SLEEP=0.05 \
    DEVFLOW_SHARD_DISPATCHER="$PSR_T7/dispatch.sh" "./$psr_flavor" lib/test/run-parallel.sh 2>&1)"
  assert_eq "psr shape: the DEVFLOW_BASH boundary reaches the coordinator via $psr_flavor" "yes" \
    "$(case "$PSR_SEL_OUT" in *"2 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
done
# Unset and empty both select the default `bash`; an invalid selector fails loudly at
# the invocation boundary rather than silently running nothing.
PSR_SEL_OUT="$(cd "$PSR_T7" && SYN_SHARDS=alpha SYN_SLEEP=0.05 \
  DEVFLOW_SHARD_DISPATCHER="$PSR_T7/dispatch.sh" "${DEVFLOW_BASH_UNSET_PROBE:-bash}" lib/test/run-parallel.sh 2>&1)"
assert_eq "psr shape: an unset selector falls back to bash and still runs" "yes" \
  "$(case "$PSR_SEL_OUT" in *"2 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
PSR_EMPTY_SEL=""
PSR_SEL_OUT="$(cd "$PSR_T7" && SYN_SHARDS=alpha SYN_SLEEP=0.05 \
  DEVFLOW_SHARD_DISPATCHER="$PSR_T7/dispatch.sh" "${PSR_EMPTY_SEL:-bash}" lib/test/run-parallel.sh 2>&1)"
assert_eq "psr shape: an empty selector falls back to bash and still runs" "yes" \
  "$(case "$PSR_SEL_OUT" in *"2 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
( cd "$PSR_T7" && "./not-a-bash-at-all" lib/test/run-parallel.sh >/dev/null 2>&1 )
assert_eq "psr shape: an invalid selector fails loudly rather than reporting a clean suite" "yes" \
  "$([ "$?" -ne 0 ] && echo yes || echo no)"

# ── run root: fallback, refusal, and exhaustion ──────────────────────────────
# A checkout whose `.prflow` path cannot hold the run root stands in for a read-only
# checkout: the mechanism under test is "the checkout root is unusable", and blocking
# it with a regular file is enforced for every user, where a chmod is not enforced for
# a privileged one — a probe that silently passes under root would be a vacuous guard.
PSR_T8="$(psr_make_tree)"; psr_plant_dispatcher "$PSR_T8"
: > "$PSR_T8/.prflow"
PSR_FALLBACK_TMP="$PSR_ROOT/fallback-tmp"; mkdir -p "$PSR_FALLBACK_TMP"
PSR_RR_OUT="$(cd "$PSR_T8" && SYN_SHARDS=alpha SYN_SLEEP=0.05 TMPDIR="$PSR_FALLBACK_TMP" \
  DEVFLOW_SHARD_DISPATCHER="$PSR_T8/dispatch.sh" bash lib/test/run-parallel.sh 2>&1)"
assert_eq "psr run-root: an unusable checkout root falls back to TMPDIR and completes" "yes" \
  "$(case "$PSR_RR_OUT" in *"2 passed, 0 failed"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr run-root: the fallback is announced, not silent" "yes" \
  "$(case "$PSR_RR_OUT" in *"checkout run root unusable"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr run-root: the fallback root is under TMPDIR" "yes" \
  "$([ -d "$PSR_FALLBACK_TMP/devflow-parallel-suite" ] && echo yes || echo no)"
# Both roots unusable → a named diagnostic BEFORE any completion claim.
PSR_BAD_TMP="$PSR_ROOT/bad-tmp"; : > "$PSR_BAD_TMP"
PSR_RR_OUT="$(cd "$PSR_T8" && SYN_SHARDS=alpha TMPDIR="$PSR_BAD_TMP" \
  DEVFLOW_SHARD_DISPATCHER="$PSR_T8/dispatch.sh" bash lib/test/run-parallel.sh 2>&1)"
assert_eq "psr run-root: with no writable root the run refuses by name" "yes" \
  "$(case "$PSR_RR_OUT" in *"could not allocate a writable run root"*) echo yes ;; *) echo no ;; esac)"
assert_eq "psr run-root: an unwritable root claims no result" "yes" \
  "$(case "$PSR_RR_OUT" in *passed,*) echo no ;; *) echo yes ;; esac)"
# Exhaustion: every candidate name this PID would try is already taken. `exec`
# preserves the PID, so the collision set is built deterministically rather than raced.
PSR_T9="$(psr_make_tree)"; psr_plant_dispatcher "$PSR_T9"
PSR_RR_OUT="$(cd "$PSR_T9" && SYN_SHARDS=alpha TMPDIR="$PSR_BAD_TMP" bash -c '
  set -u
  n=0
  while [ "$n" -lt 50 ]; do
    mkdir -p ".prflow/tmp/parallel-suite/run-$$-$n"
    n=$((n + 1))
  done
  export DEVFLOW_SHARD_DISPATCHER="$PWD/dispatch.sh"
  exec bash lib/test/run-parallel.sh
' 2>&1)"
assert_eq "psr run-root: an exhausted candidate name space refuses by name" "yes" \
  "$(case "$PSR_RR_OUT" in *"could not allocate a writable run root"*) echo yes ;; *) echo no ;; esac)"

rm -rf "$PSR_ROOT"
