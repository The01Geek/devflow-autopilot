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
  local pass="$1" fail="$2" skip="${3-}" skips_file="${4-}" tab line rest kind name reason
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
  # Itemization uses the SAME definition of "a skip line" as the tally (run.sh's `grep -c .`):
  # every NON-EMPTY line is itemized, so the announced count and the emitted lines agree
  # definitionally — not merely because the producer happens to fill every field. A line whose
  # NAME field is empty (possible only in a log skip() did not write — skip() normalizes an
  # empty name at the producer) is still itemized, under the matching "(unnamed check)"
  # placeholder (the fail-closed cosmetic-sanitization idiom): silently dropping it would make
  # the reconciliation breadcrumbs below fire on a healthy log and name the wrong cause. The
  # `|| [ -n "$line" ]` keeps a final unterminated line (which `grep -c .` counts) itemized too.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    kind="${line%%"$tab"*}"
    case "$line" in
      *"$tab"*) rest="${line#*"$tab"}" ;;
      *)        rest="" ;;
    esac
    name="${rest%%"$tab"*}"
    case "$rest" in
      *"$tab"*) reason="${rest#*"$tab"}" ;;
      *)        reason="" ;;
    esac
    [ -n "$name" ] || name="(unnamed check)"
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

# devflow_render_failure_recap FAIL NAMES_FILE
#
# Print the suite's terminal `Failure recap` to stdout — one bullet per failing assertion
# identifier, read from the record run.sh's `record_fail` appends to at every FAIL site
# (issue #789). It lives here, beside devflow_render_test_summary, because this file already
# IS the "itemize a population from a sibling record file" renderer: the SKIP half above does
# exactly this job, down to the announced-tally-vs-itemized-lines reconciliation, and a second
# inline copy at run.sh's tail would be a weaker one that nothing could unit-test directly.
#
#   FAIL == 0   → prints NOTHING and returns 0. A clean run's terminal output is therefore
#                 byte-identical to the pre-#789 output (the issue-#456 contract), by the same
#                 early-return shape the skip == 0 arm above uses.
#   FAIL  > 0   → a blank line, `Failure recap:`, then `  - <identifier>` per recorded line.
#
# The recap's value is that it covers BOTH streams: roughly three quarters of the suite's FAIL
# sites print their detail to stderr, so a reader recovering "which assertion failed?" from a
# stdout-only capture sees the tally and none of the names. The record is stream-independent.
#
# This function never sets the exit code — run.sh's FAIL-is-zero predicate remains its last
# statement, so a failing suite still exits non-zero through the recap. That is load-bearing
# beyond tidiness: scripts/verification-flight.py records the single-flight terminal state from
# that exit status, and a masked code would record a pass for a RED suite.
devflow_render_failure_recap() {
  local fail="${1-}" names_file="${2-}" line emitted=0
  # An underivable FAIL is not a reason to print a recap over an unknown population; the
  # caller's own fail-closed guard has already refused to render a summary in that case.
  devflow_tally_is_derivable "$fail" || return 0
  [ "$fail" -gt 0 ] || return 0
  echo
  echo "Failure recap:"
  if [ -z "$names_file" ] || [ ! -f "$names_file" ] || [ ! -r "$names_file" ]; then
    printf '  - (detail unavailable — the failure-identifier record is absent or unreadable)\n'
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '  - %s\n' "$line"
    emitted=$((emitted + 1))
  done < "$names_file"
  # Same two-directional reconciliation the SKIP half performs, and for the same reason: a
  # header that reads complete while the bullets are short is exactly the laundering this file
  # exists to prevent. A shortfall means some FAIL site tallied a failure without recording an
  # identifier — the reader is shown a list that silently omits the failure they are chasing.
  #
  # One shortfall source is STRUCTURAL and expected rather than a defect: a pooled or module
  # suite records its verdicts to a PRIVATE tally that module-harness.sh folds in wholesale
  # (`cat "$tally" >> "$RESULTS_FILE"`), so its failures raise the count without ever passing
  # through record_fail. The honest report for that is exactly this line — the named failures
  # plus a count of the unnamed — never a short list presented as the whole population.
  if [ "$emitted" -lt "$fail" ]; then
    printf '  - (%s of %s failure(s) recorded no identifier — the recap is INCOMPLETE; scan the captured output for `  FAIL ` lines)\n' \
      "$((fail - emitted))" "$fail"
  elif [ "$emitted" -gt "$fail" ]; then
    printf '  - (the identifier record lists %s more failure(s) than the announced tally of %s — tally and record disagree; the failure population of this run is unverified)\n' \
      "$((emitted - fail))" "$fail"
  fi
}
