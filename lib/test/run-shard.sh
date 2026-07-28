#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Shard dispatcher for the concurrent CI job matrix (issue #877).
#
# The required merge-gate check `lib + python tests` used to be one sequential job
# running `bash lib/test/run.sh` (~14 min). It is now satisfied by several shard
# jobs running concurrently, recombined by an aggregator job that keeps that exact
# name. This script is what one shard job runs: it maps a shard name to its work,
# captures the output, and writes a per-shard tally directory (via shard-tally.py)
# for the aggregator to download and recombine.
#
# The two tiers, deduplicated so nothing is counted twice across shards:
#   * the `monolith` shard runs run.sh with DEVFLOW_SKIP_SUITE_MODULES=1, i.e. every
#     inline assertion EXCEPT the module tier;
#   * each module shard runs `run-module.sh <id>` for the module ids in its group.
# The union of every module group is exactly the registered module set — no module
# is dropped (coverage is preserved), which lib/test/run.sh asserts against the
# registry.
#
# Usage:
#   bash lib/test/run-shard.sh <shard-name>     run a shard, write its tally dir
#   bash lib/test/run-shard.sh --list-shards    print every shard name (matrix source)
#   bash lib/test/run-shard.sh --modules-of S    print the module ids in shard S
#                                                (empty for the monolith shard)
#
# The tally directory is $DEVFLOW_SHARD_TALLY_DIR, defaulting to
# .devflow/tmp/shard-tally/<shard>. Exit status is the shard's own pass/fail state.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# ── Shard → work map (single source of truth) ────────────────────────────────
# The monolith shard is the sentinel; every other shard names a space-separated
# module-id group. Keep the union of the module groups equal to the registered
# module set in scripts/workflow-flight-recorder-registry.json (asserted in run.sh).
SHARD_NAMES="monolith modules-pin modules-large modules-rest"

_shard_modules() { # shard-name -> prints module ids (empty for monolith)
  case "$1" in
    monolith)      printf '' ;;
    modules-pin)   printf '%s' 'harness-python-guards' ;;
    modules-large) printf '%s' 'retrospective-lifecycle review-trigger-helpers create-issue-contract review-stall-backstop' ;;
    modules-rest)  printf '%s' 'workflow-flight-recorder review-and-fix-contract capability-profiles regenerate-artifacts installer-wiring prompt-extension-reader experiment-records' ;;
    *) return 2 ;;
  esac
}

_is_known_shard() { # shard-name -> rc 0 when known
  # _shard_modules is the single source of truth for the shard set: it returns rc 2
  # for an unknown shard and rc 0 (printing the group, empty for monolith) for a
  # known one, so membership derives from it rather than a second enumeration.
  _shard_modules "$1" >/dev/null 2>&1
}

# ── Query modes (used by the CI matrix and by run.sh's coupling assertions) ───
case "${1-}" in
  --list-shards)
    for s in $SHARD_NAMES; do printf '%s\n' "$s"; done
    exit 0
    ;;
  --modules-of)
    [ "$#" -ge 2 ] || { printf 'run-shard.sh: --modules-of requires a shard name\n' >&2; exit 2; }
    _is_known_shard "$2" || { printf 'run-shard.sh: unknown shard %s\n' "$2" >&2; exit 2; }
    mods="$(_shard_modules "$2")"
    [ -z "$mods" ] || printf '%s\n' $mods
    exit 0
    ;;
  --help|-h|'')
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --*)
    printf 'run-shard.sh: unknown option %s\n' "$1" >&2
    exit 2
    ;;
esac

SHARD="$1"
_is_known_shard "$SHARD" || { printf 'run-shard.sh: unknown shard %s (known: %s)\n' "$SHARD" "$SHARD_NAMES" >&2; exit 2; }

TALLY_DIR="${DEVFLOW_SHARD_TALLY_DIR:-$REPO_ROOT/.devflow/tmp/shard-tally/$SHARD}"
mkdir -p "$TALLY_DIR" || { printf 'run-shard.sh: could not create tally dir %s\n' "$TALLY_DIR" >&2; exit 2; }
LOG_FILE="$TALLY_DIR/log.txt"

shard_rc=0
: > "$LOG_FILE"

MODS="$(_shard_modules "$SHARD")"
if [ -z "$MODS" ]; then
  # Monolith shard: the whole suite minus the module tier (dedup) so it never
  # re-runs the modules the module shards own.
  TIER=monolith
  printf 'run-shard.sh: monolith shard — bash lib/test/run.sh (DEVFLOW_SKIP_SUITE_MODULES=1)\n'
  DEVFLOW_SKIP_SUITE_MODULES=1 bash "$SCRIPT_DIR/run.sh" >> "$LOG_FILE" 2>&1 || shard_rc=$?
else
  # Module shard: run each module in the group; any module failure fails the shard.
  TIER=modules
  for mid in $MODS; do
    printf 'run-shard.sh: module %s — bash lib/test/run-module.sh %s\n' "$mid" "$mid"
    bash "$SCRIPT_DIR/run-module.sh" "$mid" >> "$LOG_FILE" 2>&1 || shard_rc=1
  done
fi

# Echo the captured log so the shard job's own log carries the detail too.
cat "$LOG_FILE" || true

# Extract the tally. shard-tally.py fails closed: a non-zero shard_rc with no
# parsed failure still records a failure, so a crashed shard never recombines green.
python3 "$SCRIPT_DIR/shard-tally.py" extract \
  --shard "$SHARD" --tier "$TIER" --log "$LOG_FILE" --rc "$shard_rc" --out "$TALLY_DIR"
extract_rc=$?

exit "$extract_rc"
