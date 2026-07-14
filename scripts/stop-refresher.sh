#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# stop-refresher.sh — retire the detached credential refresher and surface its
# health at the job level (issue #487). Extracted from the workflows' inline
# `Stop credential refresher` step so the branch selection and the composed
# user-facing `::warning::` are drivable by the test suite (the CLAUDE.md
# inline-shell-extraction convention; scripts/describe-denial-count.sh precedent).
#
# It (a) kills the refresher by the pidfile the loop wrote, (b) tails the detached
# refresher's log into the step output — the refresher's own `::warning::` lines are
# INERT in a background process (GitHub Actions interprets `::warning::` only on a
# live step's stdout) — and (c) re-emits ONE real, live `::warning::` when the
# refresher was DEFEATED, so a run that silently lost its credentials is visible in
# the job UI without log archaeology.
#
# "Defeated" is decided honestly, avoiding the two failure modes a naive
# grep-for-any-failure gate has:
#   * never-started / crashed-before-first-cycle → the pidfile is ABSENT (the loop
#     writes it at startup), so a missing pidfile IS the defeat signal — this
#     catches a missing/unparseable vendored script (whose `bash: … .sh:` error the
#     warn-prefix grep would miss) and an early crash.
#   * sustained vs. recovered failure → read the LAST `refresh-app-credentials:`
#     line: `cycle OK` means the most recent cycle refreshed the credentials (a
#     transient the backoff recovered from — do NOT warn); a `::warning::` last line
#     means the most recent cycle failed (a real stale-token risk — warn).
#
# Best-effort: ALWAYS exits 0 (a stop hiccup never fails the job).
#
# Env (all optional; defaults match the refresher + the workflow):
#   RUNNER_TEMP                 base dir for the default pidfile/log paths
#   DEVFLOW_REFRESH_PIDFILE     pidfile path (default $RUNNER_TEMP/devflow-refresh.pid)
#   DEVFLOW_REFRESH_LOG         log path     (default $RUNNER_TEMP/devflow-refresh.log)
#   DEVFLOW_REFRESH_STARTED     the Start step's outcome (`success` when it ran). An
#                               absent pidfile only means "defeated" when the Start
#                               step actually RAN — otherwise (the job aborted
#                               upstream and skipped the success()-gated Start step)
#                               a missing pidfile is EXPECTED, not a defeat, and
#                               warning would misattribute an unrelated early failure
#                               to the refresher.

set -uo pipefail

PIDFILE="${DEVFLOW_REFRESH_PIDFILE:-${RUNNER_TEMP:-/tmp}/devflow-refresh.pid}"
LOG="${DEVFLOW_REFRESH_LOG:-${RUNNER_TEMP:-/tmp}/devflow-refresh.log}"
STARTED="${DEVFLOW_REFRESH_STARTED:-success}"   # default success: a direct/test run has no gate

defeated=no
reason=""

if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    echo "signalled credential refresher (pid $pid)"
  else
    echo "refresher pidfile '$PIDFILE' is empty; nothing to signal"
  fi
elif [ "$STARTED" = success ]; then
  # The Start step ran (launched the nohup) yet no pidfile exists → the refresher
  # never started or crashed before writing it (e.g. a missing/unparseable vendored
  # script, whose `bash: … .sh:` error the warn-prefix grep would miss). Genuine defeat.
  echo "no refresher pidfile at $PIDFILE"
  defeated=yes
  reason="the refresher did not start or crashed before writing its pidfile"
else
  # The Start step did NOT run (the job aborted before reaching it), so the missing
  # pidfile is expected — do not misattribute an unrelated upstream failure to the
  # refresher.
  echo "refresher Start step did not run (outcome='$STARTED'); missing pidfile is expected, not a defeat"
fi

if [ -f "$LOG" ]; then
  echo "--- credential refresher log (tail) ---"
  tail -n 40 "$LOG" 2>/dev/null || true
  # Only consult the log for the sustained-vs-recovered decision when the pidfile
  # was present (an absent pidfile already decided defeat above, and its cause is
  # more fundamental than any log line).
  if [ "$defeated" = no ]; then
    last="$(grep -E 'refresh-app-credentials:' "$LOG" 2>/dev/null | tail -n1)"
    case "$last" in
      *"cycle OK"*) : ;;                    # most recent cycle succeeded → creds fresh
      *"::warning::"*) defeated=yes; reason="the most recent refresh cycle failed" ;;
      *) : ;;                               # no cycle outcome logged yet → nothing to assert
    esac
  fi
fi

if [ "$defeated" = yes ]; then
  echo "::warning::credential refresher may not have kept credentials fresh ($reason); git push / gh calls past ~60 min may have used a stale token — see the refresher log tail above"
fi

exit 0
