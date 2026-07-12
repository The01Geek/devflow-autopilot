#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# extract-execution-shape.sh — read a claude-code-action execution file and emit a
# REDACTED shape record: which of a fixed set of telemetry fields it carries
# (present/absent/unavailable), its top-level encoding, and a redacted structural
# key→type set. A pure read-only diagnostic used by the repo-internal execution-file
# shape probe in .github/workflows/matcher-probe.yml (issue #437) and its unit tests.
# It NEVER changes the caller's pass/fail result and ALWAYS exits 0 — mirroring
# scripts/surface-execution-diagnostics.sh's best-effort, breadcrumb-on-degradation
# contract.
#
# WHY THIS EXISTS. Every telemetry floor DevFlow has built rests on an operand the
# agent must volunteer. Whether an agent-INDEPENDENT floor is possible turns on what
# the harness's own execution_file actually carries — a question the repo asserted
# ("the cost half is unreconstructable") but never measured. This helper is the
# measurement instrument: the probe job feeds a real cloud run's execution_file
# through it and uploads the redacted output as evidence, and docs/execution-file-shape.md
# records what was observed.
#
# REDACTION IS A SECURITY BOUNDARY, NOT A NICETY (issue #437 AC2). The execution file
# can carry prompt text, repository content, and attacker-controlled check-run names.
# So EVERY string leaf is redacted: the structural section emits each object's immediate
# key→TYPE pairs only (a string VALUE is rendered as the type token `string`, never its
# bytes), and no scalar value is ever printed. What ships to a maintainer's artifact
# download is the SHAPE (each object's immediate keys + value types), never the content.
# Scope note: redaction targets string *values* (the leaves that carry prompt/repo/
# check-run content in the observed claude-code-action schema); object *keys* are the
# fixed schema field names and are emitted verbatim — no field in the observed schema
# places untrusted content in a key position.
#
# ENCODING TOLERANCE (issue #437 AC5). claude-code-action's execution_file schema is
# not a public contract, and scripts/surface-execution-diagnostics.sh / parse-engine-error.sh
# already tolerate three encodings. This helper RECORDS which one it observed —
# confirming or narrowing that tolerance — one of:
#   - array : a single top-level JSON array of stream events
#   - object: a single top-level JSON result object
#   - jsonl : one JSON object per line
#   - unavailable: the file is absent/empty/unparseable (never conflated with "absent")
#
# FIELD DETERMINATION (issue #437 AC3/AC4). For each field the record states one of:
#   - present     : observed in the parsed file
#   - absent      : the file parsed AND carried a result event, but the field was not seen
#   - unavailable : the field could not be established — the file is absent/empty/
#                   unparseable, OR carried no result event (an incomplete/aborted run).
# `absent` and `unavailable` are DELIBERATELY DISTINCT (the unknown-is-not-zero rule):
# a full run that simply lacks `usage` records `absent`; a run we could not read at all
# records `unavailable`. Neither is ever collapsed onto the other, and nothing is ever
# reported as `0`.
#
# Usage: extract-execution-shape.sh [EXECUTION_FILE]
#   EXECUTION_FILE  path to the claude-code-action execution log.
#
# $DEVFLOW_JQ overrides the `jq` binary (the same seam the rest of devflow uses;
# honored by the sourced resolver below).

set -uo pipefail

_EES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Guarded source (matches surface-execution-diagnostics.sh / the documented
# partial-copy posture — see CLAUDE.md): a deployment carrying this file without its
# sibling lib/resolve-jq.sh must degrade to bare `jq` with a breadcrumb, never leave
# DEVFLOW_JQ unbound and abort the next reference under `set -u`.
# shellcheck source=../lib/resolve-jq.sh
. "$_EES_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced from ../lib relative to ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
# Outcome check, not just sourceability: a sibling that sources clean yet never
# assigns must still leave a usable jq — never a bare `set -u` abort that breaks the
# always-exit-0 contract.
if [ -z "${DEVFLOW_JQ:-}" ]; then
  echo "devflow: resolve-jq.sh sourced but did not assign DEVFLOW_JQ — using bare 'jq' (set DEVFLOW_JQ to override)" >&2
  DEVFLOW_JQ=jq
fi

_HEADER="# Execution-file shape record"

# Emit an all-unavailable record (the degradation shape) and exit 0. $1 is a short
# reason surfaced both as a stderr breadcrumb (naming the file, so a renamed/removed
# execution_file output is attributable — the id-rename hazard) and in the record
# itself, so a downstream reader sees WHY every field is unavailable.
_emit_unavailable() {
  echo "devflow: extract-execution-shape: $1 — every field unavailable" >&2
  printf '%s\n' "$_HEADER"
  printf 'encoding: unavailable\n'
  printf 'usage: unavailable\n'
  printf 'wall_clock_timing: unavailable\n'
  printf 'tool_use: unavailable\n'
  printf 'subagent_type: unavailable\n'
  printf 'permission_denials: unavailable\n'
  printf '\n## Structural key-paths (redacted; string leaves shown as type only)\n'
  printf '_(none — execution file %s)_\n' "$1"
  exit 0
}

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ] || [ ! -s "$FILE" ]; then
  _emit_unavailable "absent or empty ('$FILE')"
fi

# --- Encoding detection (AC5). Derive with the preflight-guaranteed jq + bash
# builtins ONLY: this value decides the emitted encoding line, so it must not depend
# on a non-preflight PATH tool (wc/head) that could be absent and silently mis-select
# (the guard-class-2 rule). `jq -c type` prints one type token per top-level JSON
# value: a single array/object → one line; JSONL → one line per object. Count the
# lines and read the first token with a builtin read loop, never `wc`/`head`.
ENC_TYPES="$("$DEVFLOW_JQ" -c 'type' "$FILE" 2>/dev/null)" || ENC_TYPES=""
if [ -z "$ENC_TYPES" ]; then
  # jq could not parse the file as any stream of JSON values → genuinely unparseable.
  _emit_unavailable "present but unparseable ('$FILE')"
fi
_n=0
_first=""
while IFS= read -r _t; do
  [ -z "$_t" ] && continue
  _n=$((_n + 1))
  [ "$_n" -eq 1 ] && _first="$_t"
done <<<"$ENC_TYPES"
if [ "$_n" -gt 1 ]; then
  ENCODING=jsonl
else
  case "$_first" in
    '"array"')  ENCODING=array ;;
    '"object"') ENCODING=object ;;
    # A single top-level scalar (number/string/bool/null) is not a valid execution
    # file — treat it as unavailable rather than inventing an encoding for it.
    *) _emit_unavailable "top-level is a scalar, not an execution log ('$FILE')" ;;
  esac
fi

# --- Field determination + redacted structural set, in one slurp-based jq pass.
# `-s` normalizes array / single-object / JSONL into one array; `[.. | objects]`
# reaches every object at any nesting depth (so a field carried in a nested `input`
# or a streamed message event is still seen regardless of encoding — the property the
# encodings test pins). The result event (`type=="result"`) is the completion gate:
# with none present the run is incomplete/aborted and every field is `unavailable`,
# never `absent`.
#
# REDACTION: the structural section maps every object's immediate keys to their VALUE
# TYPE only. A string value renders as the token `string` — its bytes never appear —
# so a seeded secret, a long prompt body, or a hostile check-run name (all string
# leaves) cannot survive into the output (AC2, asserted on emitted bytes downstream).
if ! BODY=$("$DEVFLOW_JQ" -rs '
    # The completion-gate + present/absent decision lives in ONE place: with no
    # result event the run is incomplete/aborted, so the field is `unavailable`
    # (never `absent`, never `0`); otherwise present/absent by observation. Folding
    # the gate into det() keeps the load-bearing absent-vs-unavailable distinction
    # single-sourced across all five fields.
    def det($hr; $b): if $hr then (if $b then "present" else "absent" end) else "unavailable" end;
    [.. | objects] as $objs
    | (any($objs[]; .type? == "result")) as $has_result
    | (any($objs[]; has("usage") and (.usage != null))) as $usage
    | (any($objs[];
        (has("duration_ms") and (.duration_ms != null))
        or (has("duration_api_ms") and (.duration_api_ms != null)))) as $timing
    | (any($objs[]; .type? == "tool_use")) as $tooluse
    | (any($objs[]; has("subagent_type") and (.subagent_type != null))) as $subagent
    | (any($objs[]; has("permission_denials") and (.permission_denials != null))) as $denials
    | det($has_result; $usage)    as $u
    | det($has_result; $timing)   as $w
    | det($has_result; $tooluse)  as $t
    | det($has_result; $subagent) as $s
    | det($has_result; $denials)  as $p
    | ( [ $objs[] | to_entries[] | "\(.key): \(.value | type)" ] | unique ) as $struct
    | [ "usage: \($u)",
        "wall_clock_timing: \($w)",
        "tool_use: \($t)",
        "subagent_type: \($s)",
        "permission_denials: \($p)",
        "",
        "## Structural key-paths (redacted; string leaves shown as type only)" ]
      + (if ($struct | length) > 0 then $struct else ["_(no object keys found)_"] end)
    | .[]
  ' "$FILE"); then
  # jq parsed the encoding probe above but failed the slurp pass (a truly pathological
  # shape, or an unrunnable jq surfacing only now). Fail closed to unavailable with a
  # breadcrumb naming the file — never emit a partial/misleading record.
  _emit_unavailable "jq slurp pass failed ('$FILE')"
fi

printf '%s\n' "$_HEADER"
printf 'encoding: %s\n' "$ENCODING"
printf '%s\n' "$BODY"
exit 0
