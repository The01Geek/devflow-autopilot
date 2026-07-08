#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# surface-execution-diagnostics.sh — surface a claude-code-action run's execution
# diagnostics (run summary + permission-denial detail) to stdout, and to
# $GITHUB_STEP_SUMMARY when that variable is set and non-empty. A pure read-only
# diagnostic: it never changes the calling step's pass/fail result, uploads no
# artifact, and always exits 0 — a maintainer debugging a stalled/incomplete/
# unexpectedly-denied cloud run gets the denial detail and run shape directly on
# the Actions run page and in the streamed log (issue #329).
#
# claude-code-action@v1 writes the execution log to the file named by
# steps.claude.outputs.execution_file. Its exact on-disk shape is not pinned by a
# public contract, so — exactly like scripts/parse-engine-error.sh — the same
# slurp-based jq traversal handles all three plausible encodings:
#   - a single JSON ARRAY of stream events (the element of type=="result" carries
#     the run summary; when several exist the LAST is used);
#   - a single result OBJECT;
#   - JSONL (one JSON object per line; `jq -s` slurps every line into an array).
# `.. | objects` then reaches the result object at any nesting depth.
#
# Per-denial detail (tool_name + tool_input) may live in the result event's
# `permission_denials` array OR in streamed message events rather than the result
# event, and no sample execution file survives to pin its exact home (issue #329's
# load-bearing assumption). So denials are gathered from ANY `permission_denials`
# array in the slurped input, and the surfacing degrades to count-only when no
# such array is present — the count (`permission_denials_count`) is always shown.
#
# Best-effort, mirroring parse-engine-error.sh: an absent, empty, unparseable, or
# result-less execution file prints an explicit "no diagnostics available" line
# and exits 0; a file with zero denials prints "No permission denials." Always
# exits 0 — the caller reads stdout, never the exit code.
#
# Usage: surface-execution-diagnostics.sh [EXECUTION_FILE]
#   EXECUTION_FILE  path to the claude-code-action execution log.
#
# $DEVFLOW_JQ overrides the `jq` binary (the same seam the rest of devflow uses;
# honored by the sourced resolver below).

set -uo pipefail

_SED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Guarded source (matches parse-engine-error.sh / the documented partial-copy
# posture — see CLAUDE.md): a deployment carrying this file without its sibling
# lib/resolve-jq.sh must degrade to bare `jq` with a breadcrumb, never leave
# DEVFLOW_JQ unbound and abort the next reference under `set -u`.
# shellcheck source=../lib/resolve-jq.sh
. "$_SED_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced from ../lib relative to ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
# Outcome check, not just sourceability: a sibling that sources clean yet never
# assigns must still leave a usable jq — never a bare `set -u` abort that breaks
# the always-exit-0 contract.
if [ -z "${DEVFLOW_JQ:-}" ]; then
  echo "devflow: resolve-jq.sh sourced but did not assign DEVFLOW_JQ — using bare 'jq' (set DEVFLOW_JQ to override)" >&2
  DEVFLOW_JQ=jq
fi

# Emit BLOCK to stdout, and append it to $GITHUB_STEP_SUMMARY when that variable
# is set and non-empty (AC2). Kept in one place so every exit path surfaces to
# both sinks identically.
_emit() {
  printf '%s\n' "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY" \
      || echo "devflow: surface-execution-diagnostics: could not append to GITHUB_STEP_SUMMARY ('$GITHUB_STEP_SUMMARY') — stdout still carries the diagnostics" >&2
  fi
}

_HEADER="## DevFlow execution diagnostics"
_NO_DIAG="$_HEADER
_No diagnostics available (execution file absent, empty, unparseable, or carrying no result event)._"

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ] || [ ! -s "$FILE" ]; then
  # Breadcrumb + explicit line: a renamed/removed execution_file output would
  # otherwise disarm this diagnostic silently (the id-rename hazard).
  echo "devflow: surface-execution-diagnostics: execution file absent or empty ('$FILE') — no diagnostics available" >&2
  _emit "$_NO_DIAG"
  exit 0
fi

# Build the whole formatted block in one slurp-based jq program. `-s` normalizes
# JSONL / single-array / single-object the same way; `.. | objects` reaches the
# result object at any depth. Denials are gathered from every `permission_denials`
# array anywhere in the slurped input (they may not live in the result event).
# tool_input is truncated to keep the surfaced block readable.
if ! BLOCK=$("$DEVFLOW_JQ" -rs --arg header "$_HEADER" '
    def trunc($s):
      ($s | tostring) as $t
      | if ($t | length) > 200 then ($t[0:200] + "…(truncated)") else $t end;
    # Null-safe field render: `//` would collapse a legitimate `false`/absent
    # is_error to the fallback (jq treats false as empty for `//`), so a plain
    # explicit null check is used instead of `.field // "n/a"`.
    def orna($v): if $v == null then "n/a" else $v end;
    (last(.. | objects | select(.type? == "result"))) as $r
    | ([.. | objects | (.permission_denials? // empty)
        | if type == "array" then .[] else . end
        | select(type == "object")]) as $denials
    | if $r == null and ($denials | length) == 0 then
        # Parsed, but no result event and no denial detail: nothing to surface.
        $header, "",
        "_No diagnostics available (no result event in execution file)._"
      else
        (if $r.permission_denials_count == null then ($denials | length) else $r.permission_denials_count end) as $count
        | $header, "",
          "### Run summary",
          "- is_error: \(orna($r.is_error))",
          "- num_turns: \(orna($r.num_turns))",
          "- duration_ms: \(orna($r.duration_ms))",
          "- total_cost_usd: \(orna($r.total_cost_usd))",
          "- permission_denials_count: \($count)",
          "",
          "### Permission denials",
          (if $count == 0 then
             "No permission denials."
           elif ($denials | length) > 0 then
             ("\($denials | length) permission denial(s) with detail:"),
             ($denials[] | "- `\(.tool_name // "unknown")`: \(trunc(.tool_input // ""))")
           else
             "\($count) permission denial(s) reported; no per-denial detail in execution file."
           end)
      end
  ' "$FILE"); then
  # jq's own stderr flows to the caller's log; add a devflow breadcrumb naming the
  # file so a broken jq / unparseable log is attributable, not silently swallowed.
  echo "devflow: surface-execution-diagnostics: jq failed parsing '$FILE' — no diagnostics available" >&2
  _emit "$_NO_DIAG"
  exit 0
fi

_emit "$BLOCK"
exit 0
