#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Decide whether THIS /devflow:implement run is a duplicate of an already-active
# run for the same issue/PR thread, so the heavy `claude` job can be skipped.
#
# Why a gate-stage check (not GitHub-native `concurrency`): the desired behavior
# is "ignore the new command, leave the in-progress run untouched". Native
# concurrency cannot express that — `cancel-in-progress: true` cancels the
# in-flight run (wrong run), and `cancel-in-progress: false` QUEUES the duplicate
# so it eventually runs (not ignored). GitHub has no "skip if already running"
# primitive, so we detect duplicates ourselves here and set `duplicate=true`,
# which the workflow uses to skip the billable job and post a brief notice.
#
# How "same thread" is identified: devflow-implement.yml sets a `run-name`
# embedding the issue/PR number the command was posted on (CONTEXT_NUMBER). We
# list this workflow's active runs and match that number out of each run's
# displayTitle. A second `/devflow:implement` posted on the same issue/PR thread
# therefore carries the same number and is detected. (Boundary: an explicit
# `/devflow:implement <n>` cross-posted on a *different* thread keys on the
# thread it was posted in, not <n> — the dominant duplicate case is repeated
# commands on one thread, which this covers.)
#
# Tie-break / no double-skip: a run defers ONLY to an active run with a SMALLER
# databaseId (an older run). GitHub run ids increase monotonically, so among any
# set of overlapping runs for one thread exactly one — the oldest — has no older
# peer and proceeds; the rest see it and ignore. This run never defers to a
# newer run, so two near-simultaneous commands cannot both skip.
#
# Inputs (env):
#   REPO            owner/repo, for the `gh run list` call.
#   CONTEXT_NUMBER  the issue/PR thread number to dedupe on (the run-name marker).
#   RUN_ID          github.run_id of THIS run (excluded from the active set; also
#                   the monotonic tie-break boundary).
#   GH_TOKEN        token for `gh`, set by the caller.
#   WORKFLOW        workflow file to scope the run list (default devflow-implement.yml).
#   DEVFLOW_GH      gh executable override for tests (default: gh).
#
# Output: one `key=value` line on stdout (the caller appends to $GITHUB_OUTPUT;
# tests assert it directly):
#   duplicate=true|false
#
# Fails OPEN: any missing input or query error yields duplicate=false (the run
# proceeds) with a ::warning::, because silently swallowing a legitimate single
# request is worse than a rare redundant run. Diagnostics go to stderr.

set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

GH="${DEVFLOW_GH:-gh}"
repo="${REPO:-}"
target="${CONTEXT_NUMBER:-}"
run_id="${RUN_ID:-}"
workflow="${WORKFLOW:-devflow-implement.yml}"

# Fail open on any missing prerequisite — we cannot reliably dedupe without all
# three, and blocking a legitimate run on our own missing context is the worse
# failure direction.
if [ -z "$repo" ] || ! [[ "$target" =~ ^[0-9]+$ ]] || ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
  echo "::warning::dedupe: missing/invalid REPO/CONTEXT_NUMBER/RUN_ID; not deduping (run proceeds)." >&2
  emit duplicate false
  exit 0
fi

# List this workflow's recent runs; keep only ACTIVE ones older than this run
# (databaseId < RUN_ID) whose run-name targets the same thread number. The
# number is matched with non-digit boundaries so target 2 never matches
# "issue 21". A query failure is fail-open.
if ! runs_json="$("$GH" run list --repo "$repo" --workflow "$workflow" \
      --limit 100 --json databaseId,displayTitle,status 2>/dev/null)"; then
  echo "::warning::dedupe: 'gh run list' failed; not deduping (run proceeds)." >&2
  emit duplicate false
  exit 0
fi

count="$(printf '%s' "$runs_json" | jq -r --argjson run "$run_id" --arg target "$target" '
  [ .[]
    | select(.status as $s | ["in_progress","queued","requested","waiting","pending"] | index($s))
    | select(.databaseId < $run)
    | select(.displayTitle | test("(^|[^0-9])" + $target + "([^0-9]|$)"))
  ] | length' 2>/dev/null || echo "")"

if ! [[ "$count" =~ ^[0-9]+$ ]]; then
  echo "::warning::dedupe: could not parse active-run count; not deduping (run proceeds)." >&2
  emit duplicate false
  exit 0
fi

if [ "$count" -gt 0 ]; then
  echo "::notice::dedupe: $count older active /devflow:implement run(s) for issue/PR #$target; ignoring this duplicate." >&2
  emit duplicate true
else
  emit duplicate false
fi
