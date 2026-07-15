#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# prepare-harness-floor.sh — the backstop-step glue for the harness-side cost floor
# (issue #475). It is the branch-selecting shell the CLAUDE.md inline-workflow-shell
# convention keeps OUT of the workflow YAML (the scripts/describe-denial-count.sh
# precedent): a mis-selected arm here silently defeats the floor while the workflow
# still "works", so every branch is driven directly by lib/test/run.sh.
#
# Usage:
#   prepare-harness-floor.sh <execution_file> <command> <candidate_number> <cost_out_file>
#
#   <execution_file>   claude-code-action's steps.claude.outputs.execution_file path.
#   <command>          the gate's resolved command (a full `/devflow:<class> [N]`
#                      string on devflow.yml, or the bare class `implement` on
#                      devflow-implement.yml). The class and an explicit trailing PR
#                      number are parsed from it.
#   <candidate_number> the fallback context number: the PR the command ran on
#                      (devflow.yml), or the ISSUE number the implement run is for
#                      (devflow-implement.yml).
#   <cost_out_file>    where the reader's normalized cost JSON is written (empty/absent
#                      when the floor is inert). The backstop step reads it into
#                      DEVFLOW_EXECUTION_COST.
#
# It:
#   1. runs scripts/extract-execution-cost.py over the execution file → the cost JSON;
#   2. normalizes <command> to a class and extracts an explicit trailing PR number;
#   3. resolves/verifies the PR the record is keyed to (gh via lib/resolve-gh.sh);
#   4. prints two eval-able env assignments to STDOUT — DEVFLOW_EXECUTION_PR and
#      DEVFLOW_COMMAND_CLASS — for the `bash "$HELPER" --persist` line.
#
# Every non-happy branch emits a SPECIFIC ::warning:: so a skipped skeleton/inert floor
# is auditable in the step log. Best-effort: ALWAYS exits 0 (the ensure-label.sh
# contract), so the always() backstop step is never aborted.
set -uo pipefail

# gh: resolved once via the shared execution-verified resolver (a non-empty DEVFLOW_GH
# still wins, so the test stub is untouched). The verify/resolve calls below run under
# GH_TOKEN=github.token (job-lifetime-valid; the job-start App token may be past its
# ~60-minute lifetime by backstop time — the #287 hazard).
# shellcheck source=../lib/resolve-gh.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$HERE/extract-execution-cost.py"

EXEC_FILE="${1:-}"
COMMAND="${2:-}"
CANDIDATE="${3:-}"
COST_OUT="${4:-}"

# Emit the two eval-able env assignments and exit 0. $1 = PR (digits or empty),
# $2 = command class (a known class or empty). Single-quoting is safe because both are
# sanitized to a fixed shape before this is called.
_emit() {
  printf "DEVFLOW_EXECUTION_PR='%s'\n" "$1"
  printf "DEVFLOW_COMMAND_CLASS='%s'\n" "$2"
  exit 0
}

# The reader intentionally prints a normalized all-null object for a parsed file with no
# figures (AC2). That object is valid reader output but is not cost coverage. Consume the
# reader's normalized JSON contract directly and succeed only when at least one top-level
# figure, per-token figure, or model-usage object is established.
_cost_has_figures() {
  printf '%s' "$1" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
tokens = value.get("tokens")
has_figure = any(
    value.get(key) is not None
    for key in ("cost_usd", "model_usage", "num_turns", "duration_ms")
)
if isinstance(tokens, dict):
    has_figure = has_figure or any(item is not None for item in tokens.values())
raise SystemExit(0 if has_figure else 1)
' 2>/dev/null
}

# ── Normalize the command to a class + optional explicit PR number ───────────
CMD="${COMMAND#/devflow:}"          # strip a leading /devflow: if present
CLASS="${CMD%% *}"                  # first token
REST="${CMD#"$CLASS"}"; REST="${REST# }"   # trailing args, one leading space dropped
EXPLICIT_NUM=""
case "$REST" in
  ''|*[!0-9]*) : ;;                 # no purely-numeric explicit target
  *) EXPLICIT_NUM="$REST" ;;        # `/devflow:review-and-fix 123` → 123
esac
# Sanitize the class to the known vocabulary; anything else is "" (no record class).
case "$CLASS" in
  review|review-and-fix|pr-description|implement) : ;;
  *) CLASS="" ;;
esac

# ── Run the reader over the execution file → cost JSON ───────────────────────
# Named inert breadcrumb (AC7) for the absent/empty file — the id-rename hazard would
# otherwise disarm the floor silently.
if [ -z "$EXEC_FILE" ] || [ ! -f "$EXEC_FILE" ] || [ ! -s "$EXEC_FILE" ]; then
  echo "::warning::prepare-harness-floor: harness cost floor inert this run: execution file absent" >&2
  [ -n "$COST_OUT" ] && : > "$COST_OUT" 2>/dev/null || true
  _emit "" "$CLASS"
fi
# Do NOT suppress the reader's stderr: its breadcrumb (OSError / empty / JSON-garbage —
# the exact reason COST comes back empty here) must reach the step log so the "see the
# reader's breadcrumb" message below points at a breadcrumb that actually appears. Only
# stdout is captured into COST; the reader's stderr flows to this step's log.
COST="$(python3 "$READER" "$EXEC_FILE" || true)"
if [ -z "$COST" ]; then
  echo "::warning::prepare-harness-floor: harness cost floor inert this run: execution file could not be parsed for cost (see the reader's breadcrumb above)" >&2
  [ -n "$COST_OUT" ] && : > "$COST_OUT" 2>/dev/null || true
  _emit "" "$CLASS"
fi
if ! _cost_has_figures "$COST"; then
  echo "::warning::prepare-harness-floor: harness cost floor inert this run: execution file carried no cost or usage figures; refusing to stage an all-null harness_cost" >&2
  [ -n "$COST_OUT" ] && : > "$COST_OUT" 2>/dev/null || true
  _emit "" "$CLASS"
fi
# Cost is available — stage it for --persist.
if [ -n "$COST_OUT" ]; then
  printf '%s\n' "$COST" > "$COST_OUT" 2>/dev/null \
    || echo "::warning::prepare-harness-floor: could not write cost JSON to '$COST_OUT'; the merge/skeleton arms will be inert this run" >&2
fi

# ── Resolve DEVFLOW_EXECUTION_PR (the skeleton slug; merge arm does not need it) ──
# Verify NUM names a real PR via REST (the {owner}/{repo} placeholder form that works
# under a repo-scoped token — CLAUDE.md's gh-porcelain gotcha). Returns 0 iff NUM is a PR.
_verify_pr() {
  local n="$1" out
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  out="$("$DEVFLOW_GH" api "repos/{owner}/{repo}/pulls/$n" --jq '.number' 2>/dev/null)" && [ "$out" = "$n" ]
}

# Resolve the PR that CLOSES issue $1 (the implement case — "the PR opened for the
# issue"). Uses `gh pr list --search … --json closingIssuesReferences`, the same
# branch-naming-independent closes-issue predicate lib/scan.sh and the Phase-1 resume
# pre-check use. Prints the PR number (or nothing). Best-effort.
_resolve_pr_for_issue() {
  local issue="$1" num
  case "$issue" in ''|*[!0-9]*) return 1 ;; esac
  num="$("$DEVFLOW_GH" pr list --search "${issue} in:body" --state all \
        --json number,closingIssuesReferences \
        --jq "map(select(any(.closingIssuesReferences[]?; .number == ${issue}))) | (.[0].number // empty)" 2>/dev/null)" || return 1
  [ -n "$num" ] || return 1
  printf '%s\n' "$num"
}

case "$CLASS" in
  pr-description)
    # "no record" is pr-description's healthy by-design state (AC6): no skeleton.
    echo "::warning::prepare-harness-floor: no record by design for command class 'pr-description'; DEVFLOW_EXECUTION_PR left empty (no skeleton)" >&2
    _emit "" "$CLASS" ;;
  review|review-and-fix)
    NUM="${EXPLICIT_NUM:-$CANDIDATE}"
    if [ -z "$NUM" ]; then
      echo "::warning::prepare-harness-floor: no PR number resolved for command class '$CLASS' (empty command target and context number); DEVFLOW_EXECUTION_PR left empty" >&2
      _emit "" "$CLASS"
    fi
    if _verify_pr "$NUM"; then
      _emit "$NUM" "$CLASS"
    else
      echo "::warning::prepare-harness-floor: candidate number '$NUM' does not name a real PR (not a PR, or the gh lookup failed); DEVFLOW_EXECUTION_PR left empty (skeleton skipped)" >&2
      _emit "" "$CLASS"
    fi ;;
  implement)
    if PR="$(_resolve_pr_for_issue "$CANDIDATE")"; then
      _emit "$PR" "$CLASS"
    else
      echo "::warning::prepare-harness-floor: could not resolve the PR opened for issue '$CANDIDATE' (no closing PR found, or the gh lookup failed); DEVFLOW_EXECUTION_PR left empty (skeleton skipped)" >&2
      _emit "" "$CLASS"
    fi ;;
  *)
    echo "::warning::prepare-harness-floor: unrecognized command '$COMMAND' (no record-deriving class); DEVFLOW_EXECUTION_PR left empty" >&2
    _emit "" "$CLASS" ;;
esac
