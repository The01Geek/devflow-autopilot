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
# (derived with `grep -c` over SKIPS_FILE, the SAME mechanism as PASS/FAIL, so no
# non-preflight PATH tool decides the emitted summary — CLAUDE.md guard-class 2). SKIPS_FILE
# is the tab-separated skip log run.sh's skip() helper appends to — one
# `kind<TAB>name<TAB>reason` line per skip — read here only to list each skipped check.
#
#   K == 0 → "N passed, M failed"  (byte-identical to the pre-#456 output)
#   K  > 0 → "N passed, M failed, K skipped"
#            followed by one "  SKIP  <name> [<kind>] — <reason>" line per skipped check.
#
# This function never sets the exit code: run.sh's `[ "$FAIL" -eq 0 ]` predicate is
# unchanged, so a skip never fails the suite.
devflow_render_test_summary() {
  local pass="$1" fail="$2" skip="${3:-0}" skips_file="${4:-}" tab kind name reason
  skip="${skip:-0}"
  if [ "$skip" -eq 0 ]; then
    printf '%s passed, %s failed\n' "$pass" "$fail"
    return 0
  fi
  printf '%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
  # One line per skipped check, naming the check, its kind, and its reason.
  [ -n "$skips_file" ] && [ -f "$skips_file" ] || return 0
  tab="$(printf '\t')"
  while IFS="$tab" read -r kind name reason; do
    [ -n "$name" ] || continue
    printf '  SKIP  %s [%s] — %s\n' "$name" "$kind" "$reason"
  done < "$skips_file"
}
