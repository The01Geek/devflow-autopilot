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
# Lives in lib/test/ (not scripts/) because its only consumer is the suite:
# scripts/ vendors wholesale into every consumer install under
# .devflow/vendor/devflow/, and a test-only reporter is dead weight there.
# (describe-denial-count.sh, the pattern this follows, IS in scripts/ because a
# workflow really does call it.) CI shellchecks this file via the explicit
# lib/test list (the `git ls-files '*.sh' | grep -v '^lib/test/'` glob excludes
# lib/test/); the lint-carveout-guard.py guard fails the suite RED if a shipped
# lib/test script drops off that list (issue #717).
#
# Usage:  describe-budget-delta.sh <row-name> <before> <after>
# Exit:   0 always (a reporter must never gate the suite).
set -u

ROW="${1-}"; BEFORE="${2-}"; AFTER="${3-}"

# Arm 1: unestablished. An unmeasurable operand is reported AS unmeasurable and
# never collapsed onto a number — CLAUDE.md's "Unknown is not zero" rule: a
# missing measurement rendered as 0 would read as "no growth" and assert a state
# nobody observed.
# A missing row NAME is a caller bug, not a missing measurement — it gets its own arm
# and its own breadcrumb. Folding it into the arm below would name a cause the code
# observed to be false AND swallow a real growth warning (the helper's whole purpose).
if [ -z "$ROW" ]; then
  printf 'devflow budget: delta not reported: the caller passed no row name (before=%s after=%s)\n' \
    "${BEFORE:-<unset>}" "${AFTER:-<unset>}"
  exit 0
fi
if [ -z "$BEFORE" ] || [ -z "$AFTER" ]; then
  printf 'devflow budget: %s: delta unavailable (a before/after measurement was not established)\n' "$ROW"
  exit 0
fi
# Reachable only after the arm above proved BOTH operands non-empty: this
# concatenation cannot distinguish an empty BEFORE from an empty AFTER.
case "$BEFORE$AFTER" in
  *[!0-9]*)
    printf 'devflow budget: %s: delta unavailable (a before/after measurement was not numeric)\n' "$ROW"
    exit 0 ;;
esac
# All-digits is not the same as representable. A value past this shell's integer range
# makes BOTH comparisons below fail (`[: integer expected`, on stderr where a caller
# capturing stdout never sees it), and the chain falls through to the equal arm — so a
# vast DECREASE renders as "unchanged", asserting a state nobody observed. That is
# CLAUDE.md's "Unknown is not zero" in its purest form: unrepresentable reported as
# no-change. `[ "$x" -ge 0 ]` is the exact probe rather than a digit-length heuristic —
# it fails for precisely the values the arithmetic below cannot handle.
if ! [ "$BEFORE" -ge 0 ] 2>/dev/null || ! [ "$AFTER" -ge 0 ] 2>/dev/null; then
  printf 'devflow budget: %s: delta unavailable (a before/after measurement is outside this shell integer range)\n' "$ROW"
  exit 0
fi

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
