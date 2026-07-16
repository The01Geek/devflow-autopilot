#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# #529 AC5: report an execution-weighted prompt-traffic delta, and emit a NAMED
# justified-growth warning when a row GREW against its baseline.
#
# Why a helper and not an inline `if` in run.sh: CLAUDE.md's inline-shell rule —
# a branch-selecting chain that composes a user-facing message is extracted so
# the suite can drive each arm (and the arm ORDER), because a grep-pin on a
# message literal is not coverage of the selection that chooses it.
# `scripts/describe-denial-count.sh` is the reference implementation.
#
# Growth is a WARNING, never a hard failure: docs/workflow-flight-recorder.md
# ("Justified growth is a warning requiring recurring-cost rationale, not an
# automatic blocker") is the governing precedent.
#
# Usage:  describe-budget-delta.sh <row-name> <before> <after>
# Exit:   0 always (a reporter must never gate the suite).
set -u

ROW="${1-}"; BEFORE="${2-}"; AFTER="${3-}"

# Arm 1: unestablished. An unmeasurable operand is reported AS unmeasurable and
# never collapsed onto a number — CLAUDE.md's "Unknown is not zero" rule: a
# missing measurement rendered as 0 would read as "no growth" and assert a state
# nobody observed.
if [ -z "$ROW" ] || [ -z "$BEFORE" ] || [ -z "$AFTER" ]; then
  printf 'devflow budget: %s: delta unavailable (a before/after measurement was not established)\n' "${ROW:-(unnamed row)}"
  exit 0
fi
case "$BEFORE$AFTER" in
  *[!0-9]*)
    printf 'devflow budget: %s: delta unavailable (a before/after measurement was not numeric)\n' "$ROW"
    exit 0 ;;
esac

# Comparison and arithmetic use bash builtins only (guard-class 2: a value that
# decides an EMITTED result must not be derived through a non-preflight PATH tool).
if [ "$AFTER" -gt "$BEFORE" ]; then
  printf '::warning::devflow budget: justified-growth: %s grew by %s (before %s, after %s) — record the recurring-cost rationale in docs/review-bundle-budget.md\n' \
    "$ROW" "$((AFTER - BEFORE))" "$BEFORE" "$AFTER"
elif [ "$AFTER" -lt "$BEFORE" ]; then
  printf 'devflow budget: %s decreased by %s (before %s, after %s)\n' \
    "$ROW" "$((BEFORE - AFTER))" "$BEFORE" "$AFTER"
else
  printf 'devflow budget: %s unchanged (%s)\n' "$ROW" "$AFTER"
fi
exit 0
