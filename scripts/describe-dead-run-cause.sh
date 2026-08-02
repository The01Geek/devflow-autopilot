#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-dead-run-cause.sh — render the cause clause the dead-run
# review-progress backstop writes into the pull request's progress comment
# (issue #1154).
#
# Why a helper rather than an inline `if`/`else` in devflow.yml: this clause IS
# the diagnosis a maintainer reads off a dead run, so a silently mis-selected
# arm (a reordered chain, a typo in a comparison) defeats the feature while the
# workflow still "works". Inline shell inside YAML cannot be unit-tested; here
# lib/test/modules/review-trigger-helpers.sh drives every arm — and the arm
# ORDER — directly. Same class, and the same extraction, as
# scripts/describe-denial-count.sh (issue #363).
#
# The workflow has exactly two observables about how a run ended: the `claude`
# step's RAW outcome (`steps.claude.outcome`, before continue-on-error), and the
# engine's own `is_error`, parsed out of the execution log AFTER the step by
# scripts/parse-engine-error.sh. Those two partition the run-end space into the
# four modes below, which is why the caller no longer gates on them: it always
# runs the backstop and passes both values here to be named.
#
#   claude outcome   is_error   mode
#   ------------------------------------------------------------------
#   success          true       the engine ended in error while the step
#                               still reported success
#   success          not true   the step exited cleanly and the engine
#                               reported no error — yet no verdict was
#                               written (the run-29854795625 mode: Phase 0
#                               permission denials, no output, clean exit)
#   failure          any        the job failed
#   cancelled        any        the run was cancelled
#
# ARM ORDER IS LOAD-BEARING. The engine-error arm is tested BEFORE the
# clean-exit arm: both match `outcome == success`, and swapping them would
# report a run whose engine explicitly errored as "no verdict, no error" —
# steering the reader away from the cause the workflow already measured. Every
# later arm is keyed on a non-success outcome, so it cannot collide with either.
#
# A raw outcome outside {success, failure, cancelled} — `skipped`, or an empty
# value when the step never ran at all — is a RESIDUAL, not a fifth mode: it is
# named verbatim by the trailing arm, preserving the wording the inline chain
# this helper replaces produced for every non-success outcome.
#
# Usage: describe-dead-run-cause.sh [CLAUDE_OUTCOME] [ENGINE_IS_ERROR]
#   CLAUDE_OUTCOME    the raw `steps.claude.outcome` value, or empty.
#   ENGINE_IS_ERROR   the `steps.engine.outputs.is_error` value; only the exact
#                     literal `true` counts as an engine error (mirroring the
#                     producer, which normalizes anything else to `false`).
# Prints one clause to stdout. Always exits 0 — the backstop that consumes this
# must never change the invoking job's pass/fail result.

set -u

CLAUDE_OUTCOME="${1:-}"
ENGINE_IS_ERROR="${2:-}"

if [ "$ENGINE_IS_ERROR" = "true" ] && [ "$CLAUDE_OUTCOME" = "success" ]; then
  printf '%s\n' "review engine ended with an error (is_error)"
elif [ "$CLAUDE_OUTCOME" = "success" ]; then
  printf '%s\n' "claude step success but the run wrote no verdict (engine reported no error)"
elif [ "$CLAUDE_OUTCOME" = "failure" ]; then
  printf '%s\n' "claude step failure"
elif [ "$CLAUDE_OUTCOME" = "cancelled" ]; then
  printf '%s\n' "claude step cancelled"
elif [ -z "$CLAUDE_OUTCOME" ]; then
  printf '%s\n' "claude step outcome unavailable"
else
  printf '%s\n' "claude step ${CLAUDE_OUTCOME}"
fi
exit 0
