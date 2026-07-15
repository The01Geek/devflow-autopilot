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
#   * died mid-run → the pidfile EXISTS but its pid is no longer running (`kill -0`
#     fails; same-user runner processes, so a liveness probe never EPERMs): a
#     refresher that logged `cycle OK` and then died (OOM-killed, reaped, crashed)
#     left the credentials going stale from that moment — defeat, regardless of the
#     last log line. An EMPTY pidfile is the same unverifiable-liveness class
#     (the loop writes its PID at startup, so an empty file is anomalous) — defeat.
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
#   DEVFLOW_REFRESH_STARTED     the Start step's `outcome` (success/failure/skipped/
#                               cancelled). An absent pidfile only means "defeated"
#                               when the Start step actually RAN (outcome success OR
#                               failure) — otherwise (skipped/cancelled: the job
#                               aborted upstream before the success()-gated Start
#                               step) a missing pidfile is EXPECTED, not a defeat, and
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
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    # Briefly wait for the signalled process to actually exit before tailing its log, so
    # an in-flight cycle's final lines land in the tail rather than racing it (no
    # correctness impact on the defeat decision — that already used the PRE-kill liveness
    # probe + last log line). Bounded (~5s) so a wedged process never stalls this
    # best-effort stop; the refresher's TERM trap exits it promptly in practice.
    _wait=0
    while [ "$_wait" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 0.1
      _wait=$((_wait + 1))
    done
    echo "signalled credential refresher (pid $pid)"
  elif [ -n "$pid" ]; then
    # Pidfile present but the process is GONE: the refresher died after startup
    # (OOM-killed, reaped, crashed). Its last logged `cycle OK` proves nothing about
    # the window between that cycle and now — the credentials have been going stale
    # since the death. Genuine defeat; do NOT let a stale `cycle OK` mask it below.
    echo "refresher pidfile present but pid $pid is not running"
    defeated=yes
    reason="the refresher process died before job end (pidfile present, process gone)"
  else
    # Same unverifiable-liveness class: the loop writes its PID at startup, so an
    # empty pidfile is anomalous and the refresher's health cannot be confirmed.
    echo "refresher pidfile '$PIDFILE' is empty; nothing to signal"
    defeated=yes
    reason="the refresher pidfile is empty, so its health could not be verified"
  fi
elif [ "$STARTED" != skipped ] && [ "$STARTED" != cancelled ]; then
  # The Start step actually RAN (success OR failure — a hard Start-step failure means
  # the refresher genuinely never started) yet no pidfile exists → the refresher never
  # started or crashed before writing it (e.g. a missing/unparseable vendored script,
  # whose `bash: … .sh:` error the warn-prefix grep would miss). Genuine defeat. Keying
  # on "did it run" (not "did it succeed") is deliberate: a ran-and-failed Start is a
  # real never-started defeat, not an expected-absent-pidfile case.
  echo "no refresher pidfile at $PIDFILE"
  defeated=yes
  reason="the refresher did not start or crashed before writing its pidfile"
else
  # The Start step did NOT run (skipped/cancelled — the job aborted before reaching it),
  # so the missing pidfile is expected — do not misattribute an unrelated upstream
  # failure to the refresher.
  echo "refresher Start step did not run (outcome='$STARTED'); missing pidfile is expected, not a defeat"
fi

if [ -f "$LOG" ]; then
  echo "--- credential refresher log (tail) ---"
  tail -n 40 "$LOG" 2>/dev/null || true
  # Only consult the log for the sustained-vs-recovered decision when nothing has
  # decided defeat above (an absent pidfile, a dead pid, or an empty pidfile is a
  # more fundamental cause than any log line — a stale `cycle OK` must not mask it).
  # Cloud-only exemption (parity with refresh-app-credentials.sh's tr note): the
  # `grep`/`tail` below derive the value that GATES the user-facing defeat warning
  # (guard-class-2), and neither is a lib/preflight.sh-guaranteed tool. A missing one
  # would empty `last` → the `*)` arm → no warning (fail-open). This helper is invoked
  # ONLY from the two writer workflows on ubuntu-latest, where grep/tail are always
  # present, so the fail-open case is unreachable in the shipped invocation path.
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
