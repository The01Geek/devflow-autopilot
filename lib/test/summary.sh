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

# devflow_tally_is_derivable VALUE
#
# The shared derivability predicate for a tally. True (rc 0) when VALUE is a plain count (a
# non-empty run of digits); false (rc 1) when it is empty (a `grep -c` that errored — rc >= 2
# prints nothing) or non-numeric. Such a value is an UNESTABLISHED tally, and unknown is never
# zero: a caller that coerced it to 0 would launder a derivation failure into "nothing skipped".
#
# The predicate is a FUNCTION, not a `case` glob copy-pasted into each caller, for two reasons:
# it has exactly one definition (a mistyped glob cannot exist in only one of the two copies),
# and the suite can drive it directly over the empty/non-numeric/valid inputs rather than
# pinning its source text. It prints nothing — each caller owns its own fail-closed response
# (run.sh's tail aborts the run; the renderer below prints a loud unavailable line). Those two
# responses are deliberate defense-in-depth and stay distinct; only the predicate is shared.
devflow_tally_is_derivable() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

devflow_render_test_summary() {
  local pass="$1" fail="$2" skip="${3-}" skips_file="${4-}" tab kind name reason
  # An unestablished tally renders a loud line instead of a clean "N passed, M failed" — the
  # exact laundering this renderer exists to prevent. (Shared predicate; see above.)
  if ! devflow_tally_is_derivable "$skip"; then
    printf '%s passed, %s failed\n' "$pass" "$fail"
    printf '  SKIP  (skip tally unavailable — got "%s", not a count; the skip population of this run is unverified)\n' "$skip"
    return 0
  fi
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
  # `-r` is tested alongside `-f`, so the "absent or unreadable" wording is true of every input
  # that takes this arm: a present-but-unreadable log lands on THIS loud breadcrumb rather than
  # falling through to a read loop that silently yields no lines (which would have surfaced as
  # the shortfall breadcrumb below — loud, but naming the wrong cause).
  if [ -z "$skips_file" ] || [ ! -f "$skips_file" ] || [ ! -r "$skips_file" ]; then
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
  # The announced count and the itemized lines must AGREE, and disagreement is surfaced in BOTH
  # directions — a header that says "K skipped" while the detail lines say otherwise is the
  # laundering this renderer exists to prevent, whichever side is short. A shortfall (fewer
  # lines than announced) hides a skip the reader is never shown; an over-count (more lines
  # than announced) means the announced K under-reports the run's real skip population, so the
  # tally the reader trusts is wrong even though every skip happens to be listed. In-suite both
  # are derived from the same file and agree, so either breadcrumb means the tally and the log
  # have come apart and the skip population of the run is unverified.
  if [ "$emitted" -lt "$skip" ]; then
    printf '  SKIP  (%s of %s announced skip(s) could not be itemized from the skip log)\n' \
      "$((skip - emitted))" "$skip"
  elif [ "$emitted" -gt "$skip" ]; then
    printf '  SKIP  (skip log itemizes %s more skip(s) than the announced tally of %s — tally and log disagree; the skip population of this run is unverified)\n' \
      "$((emitted - skip))" "$skip"
  fi
}
