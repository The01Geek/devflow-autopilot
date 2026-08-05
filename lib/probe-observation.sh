#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# probe-observation.sh — the shared execution-file readers the matcher-probe
# observation renderers (scripts/describe-*-probe.sh) derive their SECONDARY
# axes from. Sourced, never executed.
#
# WHY A SHARED FILE. The hook-arm probes added by the PermissionRequest /
# PreToolUse-deny / defer jobs each need the same three reads — "is the execution
# file usable at all", "does this sentinel appear anywhere in the transcript",
# "what does permission_denials hold" — plus the observed CLI version. Copying the
# jq programs three times would make the file's undocumented on-disk shape a
# three-way coupled mirror; single-sourcing them here keeps one place to re-check
# after a claude-code-action upgrade.
#
# THE THREE-STATE DISCIPLINE (the repo's unknown-is-not-zero rule). Every reader
# separates an ESTABLISHED negative ("we parsed the transcript and the sentinel is
# not there") from an UNESTABLISHED one ("we could not read the transcript"), and
# reports the latter as the literal `unavailable`. A caller must never collapse
# `unavailable` onto `no`, `0`, or a version string.
#
# Field/array names come from the OBSERVED execution-file shape record
# (docs/execution-file-shape.observed.txt: `claude_code_version: string`,
# `permission_denials: array`), which that document itself states is a dated
# observation of one action version and NOT a schema contract — hence the
# recursive `..` searches rather than fixed paths, and hence fail-closed
# `unavailable` on every miss.
#
# Defines only; deliberately no set -e/-u — safe to source into a caller with its
# own shell options.

# Internal: the jq invocation to use. Callers source lib/resolve-jq.sh first (so
# DEVFLOW_JQ is the repo's execution-verified selection); a bare `jq` is the
# fallback, and it is execution-verified here too, so an unrunnable jq yields
# `unavailable` rather than a silent empty string.
_devflow_probe_jq() {
  local _p_jq="${DEVFLOW_JQ:-jq}"
  [ -n "$_p_jq" ] || _p_jq=jq
  "$_p_jq" --version >/dev/null 2>&1 || return 1
  printf '%s\n' "$_p_jq"
}

# devflow_probe_exec_state <execution-file>
#   Echoes `ok` when the file is present, non-empty, jq is runnable and the file
#   parses (as JSON or JSONL); echoes `unavailable` otherwise. This is the single
#   gate every other reader below consults, so "file unreadable" can never be
#   rendered as an established negative.
devflow_probe_exec_state() {
  local _p_file="${1:-}" _p_jq
  if [ -z "$_p_file" ] || [ ! -f "$_p_file" ] || [ ! -s "$_p_file" ]; then
    printf '%s\n' unavailable
    return 0
  fi
  _p_jq="$(_devflow_probe_jq)" || { printf '%s\n' unavailable; return 0; }
  # `-s` slurps array / object / JSONL encodings into one value (the same
  # tolerance surface-execution-diagnostics.sh carries).
  if "$_p_jq" -es 'true' "$_p_file" >/dev/null 2>&1; then
    printf '%s\n' ok
  else
    printf '%s\n' unavailable
  fi
  return 0
}

# devflow_probe_cli_version <execution-file>
#   Echoes the observed `claude_code_version`, or `unavailable`.
#
#   WHY IT IS RECORDED AT ALL: every matcher-probe verdict is version-dependent
#   and the action ref floats (`@v1`), so a verdict recorded without the CLI
#   version it was taken on expires silently at the next upgrade with nothing in
#   the repository noticing.
devflow_probe_cli_version() {
  local _p_file="${1:-}" _p_jq _p_out
  [ "$(devflow_probe_exec_state "$_p_file")" = ok ] || { printf '%s\n' unavailable; return 0; }
  _p_jq="$(_devflow_probe_jq)" || { printf '%s\n' unavailable; return 0; }
  _p_out="$("$_p_jq" -rs '
    [ .. | objects | .claude_code_version? | strings | select(length > 0) ] | first // empty
  ' "$_p_file" 2>/dev/null)" || _p_out=""
  # Cosmetic sanitization that fails CLOSED (the repo's rule for sanitizing with
  # anything that can come up empty): a value outside a plausible version alphabet
  # is reported unavailable rather than echoed into a Markdown step summary.
  case "$_p_out" in
    '') printf '%s\n' unavailable ;;
    *[!0-9A-Za-z._+-]*) printf '%s\n' unavailable ;;
    *) printf '%s\n' "$_p_out" ;;
  esac
  return 0
}

# devflow_probe_transcript_has <execution-file> <needle>
#   Echoes `yes` / `no` / `unavailable` for "does any string anywhere in the
#   transcript CONTAIN this needle".
#
#   `contains`, not `startswith` (the issue #908 review finding this file
#   inherits): the on-disk shape is not a pinned contract, so a hook-supplied
#   message may arrive WRAPPED inside a larger transcript string (e.g. a
#   "PreToolUse:Bash [hook] …" envelope). `startswith` reports a confident false
#   negative on exactly that shape — the one thing these probes measure. The
#   needles are distinctive sentinels, so `contains` adds no false-positive risk.
devflow_probe_transcript_has() {
  local _p_file="${1:-}" _p_needle="${2:-}" _p_jq _p_out
  if [ -z "$_p_needle" ]; then
    printf '%s\n' unavailable
    return 0
  fi
  [ "$(devflow_probe_exec_state "$_p_file")" = ok ] || { printf '%s\n' unavailable; return 0; }
  _p_jq="$(_devflow_probe_jq)" || { printf '%s\n' unavailable; return 0; }
  _p_out="$("$_p_jq" -rs --arg needle "$_p_needle" '
    [ .. | strings | select(contains($needle)) ] | length > 0
  ' "$_p_file" 2>/dev/null)" || _p_out=""
  case "$_p_out" in
    true)  printf '%s\n' yes ;;
    false) printf '%s\n' no ;;
    *)     printf '%s\n' unavailable ;;
  esac
  return 0
}

# devflow_probe_tooluse_has <execution-file> <needle>
#   Echoes `yes` / `no` / `unavailable` for "does any recorded TOOL CALL's input
#   contain this needle".
#
#   Deliberately narrower than devflow_probe_transcript_has, and the narrowing is
#   load-bearing: the transcript carries the run's own PROMPT text, and every probe
#   prompt necessarily quotes the very command tokens an "was it attempted" axis
#   searches for — so an any-string search would report a confident ATTEMPTED for a
#   command the session never issued. Only tool-call inputs answer that question.
#
#   Returns `unavailable` — never `no` — when the file records no tool-call inputs
#   at all: an empty search population cannot establish a negative, and the recorded
#   execution-file shape is a dated observation rather than a contract, so a shape
#   change must degrade to unestablished instead of forging an established negative.
devflow_probe_tooluse_has() {
  local _p_file="${1:-}" _p_needle="${2:-}" _p_jq _p_out
  if [ -z "$_p_needle" ]; then
    printf '%s\n' unavailable
    return 0
  fi
  [ "$(devflow_probe_exec_state "$_p_file")" = ok ] || { printf '%s\n' unavailable; return 0; }
  _p_jq="$(_devflow_probe_jq)" || { printf '%s\n' unavailable; return 0; }
  # Both recorded shapes: the SDK message form (`{"type":"tool_use","input":…}`)
  # and the flattened form the execution-file shape record observes
  # (`tool_name` / `tool_input`).
  _p_out="$("$_p_jq" -rs --arg needle "$_p_needle" '
    [ .. | objects
      | select((.type? == "tool_use") or (has("tool_input")))
      | [.input?, .tool_input?] | map(select(. != null)) | .[] | tojson
    ] as $inputs
    | if ($inputs | length) == 0 then "empty"
      else (($inputs | map(select(contains($needle))) | length) > 0 | tostring)
      end
  ' "$_p_file" 2>/dev/null)" || _p_out=""
  case "$_p_out" in
    true)  printf '%s\n' yes ;;
    false) printf '%s\n' no ;;
    *)     printf '%s\n' unavailable ;;
  esac
  return 0
}

# devflow_probe_denials_count <execution-file>
#   Echoes the number of `permission_denials` entries found anywhere in the
#   transcript, or `unavailable`. Zero is a REAL measured value here and is
#   deliberately distinguishable from `unavailable` — a probe that cannot read the
#   file must never publish "the harness refused 0 command(s)".
devflow_probe_denials_count() {
  local _p_file="${1:-}" _p_jq _p_out
  [ "$(devflow_probe_exec_state "$_p_file")" = ok ] || { printf '%s\n' unavailable; return 0; }
  _p_jq="$(_devflow_probe_jq)" || { printf '%s\n' unavailable; return 0; }
  _p_out="$("$_p_jq" -rs '
    [ .. | objects | .permission_denials? | arrays | .[] ] | length
  ' "$_p_file" 2>/dev/null)" || _p_out=""
  case "$_p_out" in
    ''|*[!0-9]*) printf '%s\n' unavailable ;;
    *) printf '%s\n' "$_p_out" ;;
  esac
  return 0
}

# devflow_probe_denials_have <execution-file> <needle>
#   Echoes `yes` / `no` / `unavailable` for "does the `permission_denials` array
#   itself carry this needle". Deliberately narrower than
#   devflow_probe_transcript_has: the question "did a HOOK-issued deny still land
#   in permission_denials" is only answerable against that array, never against
#   the transcript at large (where the same sentinel appears merely because the
#   hook emitted it).
devflow_probe_denials_have() {
  local _p_file="${1:-}" _p_needle="${2:-}" _p_jq _p_out
  if [ -z "$_p_needle" ]; then
    printf '%s\n' unavailable
    return 0
  fi
  [ "$(devflow_probe_exec_state "$_p_file")" = ok ] || { printf '%s\n' unavailable; return 0; }
  _p_jq="$(_devflow_probe_jq)" || { printf '%s\n' unavailable; return 0; }
  _p_out="$("$_p_jq" -rs --arg needle "$_p_needle" '
    [ .. | objects | .permission_denials? | arrays | .[] | tojson
      | select(contains($needle)) ] | length > 0
  ' "$_p_file" 2>/dev/null)" || _p_out=""
  case "$_p_out" in
    true)  printf '%s\n' yes ;;
    false) printf '%s\n' no ;;
    *)     printf '%s\n' unavailable ;;
  esac
  return 0
}
