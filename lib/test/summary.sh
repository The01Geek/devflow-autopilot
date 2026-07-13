#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Terminal-summary renderer for lib/test/run.sh (issue #456).
#
# Sourced by run.sh and driven standalone by the suite over each arm (K == 0 and
# K > 0). Kept OUT of scripts/ (which install.sh ships into consumer repos) — this is
# a DevFlow-test-only renderer, so it lives under lib/test/. lib/test/ is excluded from
# the CI shellcheck job's default glob, so this file is added to that lint's scope
# explicitly in .github/workflows/ci.yml rather than shipping unlinted.
#
# The suite has three tallies — PASS, FAIL, and SKIP. A skipped check ran neither PASS
# nor FAIL: it self-skipped because a gate that should have run here could not (a
# `blocking-gate` skip) or the host cannot express the condition (a `host-capability`
# skip). "0 failed" therefore does NOT mean "everything ran"; the summary makes the skip
# population visible so a reader — human or agent — can never mistake a skipped gate for a
# clean pass.

# devflow_render_test_summary PASS FAIL SKIP SKIPS_FILE
#
# Print the suite's terminal summary to stdout. SKIP is the skip tally run.sh maintains
# (derived with `grep -c` over SKIPS_FILE — the SAME counter mechanism PASS/FAIL already use.
# CLAUDE.md guard-class 2 bars a NEW non-preflight PATH tool from deciding an emitted result;
# the suite's PASS/FAIL selection already hard-depends on `grep`, so SKIP introduces no new
# tool into the selection). SKIPS_FILE
# is the tab-separated skip log run.sh's skip() helper appends to — one
# `kind<TAB>name<TAB>reason` line per skip — read here only to list each skipped check.
#
#   K == 0     → "N passed, M failed"  (byte-identical to the pre-#456 output)
#   K  > 0     → "N passed, M failed, K skipped"
#                followed by one "  SKIP  <name> [<kind>] — <reason>" line per skipped check.
#   K not a count (empty/non-numeric — an unestablished tally) → the pass/fail line plus a
#                loud "skip tally unavailable" line; never a silent coercion to the K == 0 arm.
#
# This function never sets the exit code: run.sh's `[ "$FAIL" -eq 0 ]` predicate is
# unchanged, so a skip never fails the suite.
devflow_render_test_summary() {
  local pass="$1" fail="$2" skip="${3-}" skips_file="${4:-}" tab kind name reason
  # A skip tally that is not a plain count — empty (a caller whose derivation errored) or
  # non-numeric — is UNESTABLISHED, and unknown is never zero: silently coercing it to 0
  # would render a clean "N passed, M failed" line and launder a derivation failure into
  # "nothing skipped", the exact laundering this renderer exists to prevent. Say so instead.
  case "$skip" in
    ''|*[!0-9]*)
      printf '%s passed, %s failed\n' "$pass" "$fail"
      printf '  SKIP  (skip tally unavailable — got "%s", not a count; the skip population of this run is unverified)\n' "$skip"
      return 0 ;;
  esac
  if [ "$skip" -eq 0 ]; then
    printf '%s passed, %s failed\n' "$pass" "$fail"
    return 0
  fi
  printf '%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
  # One line per skipped check, naming the check, its kind, and its reason. If the skip log
  # is absent/unreadable while the announced count is non-zero, emit a LOUD breadcrumb rather
  # than returning silently — a header that says "K skipped" with zero detail lines would
  # re-create the very laundering #456 exists to prevent, so the renderer stays honest
  # independent of caller discipline.
  if [ -z "$skips_file" ] || [ ! -f "$skips_file" ]; then
    printf '  SKIP  (detail unavailable — skip log absent or unreadable)\n'
    return 0
  fi
  local emitted=0
  tab="$(printf '\t')"
  while IFS="$tab" read -r kind name reason; do
    [ -n "$name" ] || continue
    printf '  SKIP  %s [%s] — %s\n' "$name" "$kind" "$reason"
    emitted=$((emitted + 1))
  done < "$skips_file"
  # The announced count and the itemized lines must agree; surface any shortfall rather than
  # leaving it silent (the honesty property above, applied to a partially-readable log).
  [ "$emitted" -ge "$skip" ] || \
    printf '  SKIP  (%s of %s announced skip(s) could not be itemized from the skip log)\n' \
      "$((skip - emitted))" "$skip"
}
