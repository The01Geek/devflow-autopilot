#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-command-job-arm.sh — decide which arm the out-of-job review finalizer
# takes from the `command` job's RESULT (issue #1174).
#
# Why a helper rather than an inline `case` in devflow.yml: the review post-run
# handlers used to be `always()` steps INSIDE the `command` job, so a runner
# death (OOM, eviction, infrastructure loss) took them down with the job — the
# one failure mode they existed to cover. devflow.yml's new `review_finalize`
# job does not share a runner with the `claude` step and survives that loss; it
# decides what to do from `needs.command.result`, the one operand a dead job
# still leaves behind. That branch-selection IS a feature the suite must be able
# to catch defeated (CLAUDE.md's inline-shell-extraction convention), so it lives
# here and lib/test/ drives every arm and the arm ORDER.
#
# THIS IS A DISTINCT DECISION FROM describe-dead-run-cause.sh, which it must not
# duplicate (issue #1174 AC6). That helper answers "what CAUSE clause do the two
# in-job observables (claude outcome + engine is_error) name" — a diagnosis
# rendered into a comment. This helper answers "did the review command job report
# at all", partitioning the JOB-level `result` into three arms:
#
#   result      arm                 meaning
#   ----------------------------------------------------------------------------
#   success     completed-normally  the job ran to completion; its own in-job
#                                   always() handlers already did their work, so
#                                   the finalizer produces NOTHING (AC3/T3).
#   cancelled   cancelled           the run was cancelled (a superseded round, a
#                                   manual cancel) — a benign non-report.
#   failure     did-not-report      the job failed or its runner was lost; the
#   skipped     did-not-report      in-job handlers may never have run, so the
#   (other/'')  did-not-report      finalizer leaves the terminal "did not
#                                   report" record this issue exists for.
#
# ARM ORDER IS LOAD-BEARING. `completed-normally` is tested FIRST so a successful
# job is never mis-graded as a non-report (which would post a dead-run banner on
# a healthy run); `cancelled` is tested before the `did-not-report` catch-all so
# a benign cancellation is named as such rather than lumped with a failure. Every
# value that is neither `success` nor `cancelled` — `failure`, `skipped`, an
# empty result when the job never started, or any unforeseen token — is a
# did-not-report RESIDUAL, deliberately caught by the trailing arm rather than
# enumerated, so an unknown result fails toward leaving the record rather than
# silently producing nothing.
#
# Usage: describe-command-job-arm.sh [COMMAND_RESULT]
#   COMMAND_RESULT   the `needs.command.result` value, or empty.
# Prints one arm token to stdout. Always exits 0 — the finalizer that consumes
# this must never change its own job's pass/fail result.

set -u

COMMAND_RESULT="${1:-}"

case "$COMMAND_RESULT" in
  success)   printf '%s\n' "completed-normally" ;;
  cancelled) printf '%s\n' "cancelled" ;;
  *)         printf '%s\n' "did-not-report" ;;
esac
exit 0
