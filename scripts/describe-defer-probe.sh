#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-defer-probe.sh — render the `defer-probe` observation for
# matcher-probe.yml's step summary.
#
# THE QUESTION. `defer` is the token scripts/pretooluse-shape-guard.py emits on
# every fail-open path, on the premise that it means "fall through to the default
# permission flow" — that file's own header records the premise as an UNESTABLISHED
# assumption. The published hooks reference says the opposite: on a `defer` the
# tool does NOT execute and the process exits with `stop_reason: "tool_deferred"`.
# If the reference is right, every one of that guard's fail-open paths is in fact
# fail-CLOSED. This arm settles which happens, on the CLI the action installs.
#
# (Settling it is all this arm does. Repairing the guard is separate work in which
# `defer` is load-bearing at several sites; nothing here changes it.)
#
# WHY THE VERDICT IS BREADCRUMB-FIRST. If the documented behavior holds, the run
# terminates on a deferred stop reason — which may leave no usable execution file
# at all. A verdict that depended on the execution file would then be unavailable
# in exactly the case it is meant to detect. So the primary axis is two on-disk
# markers, and the execution file is a corroborating secondary axis only.
#
# Usage:
#   describe-defer-probe.sh <hook-fired-marker> <tool-ran-marker> [execution-file]
#     hook-fired-marker  written by the PreToolUse hook before it emits `defer`.
#     tool-ran-marker    the on-disk side effect the single GRANTED command
#                        produces if the tool executes anyway. Present ⇒ `defer`
#                        fell through; absent (with the hook fired) ⇒ it did not.
#     execution-file     claude-code-action's execution_file output (optional) —
#                        secondary only, and expected to be missing on a honored
#                        defer.
#
# Best-effort: always exits 0; a missing required argument breadcrumbs to stderr
# and renders nothing.
#
# COUPLED SITE — the token below is one contract with the `defer-probe` job in
# .github/workflows/matcher-probe.yml (a substring of the single command its
# prompt dictates). Edit both together.

set -uo pipefail

# Substring of the single GRANTED command the probe prompt dictates.
DFR_COMMAND_TOKEN="deferprobe-tool-ran"
# The stop reason the published hooks reference attributes to a honored `defer`.
DFR_STOP_REASON="tool_deferred"

HOOK_MARKER="${1:-}"
TOOL_MARKER="${2:-}"
EXECUTION_FILE="${3:-}"

if [ -z "$HOOK_MARKER" ] || [ -z "$TOOL_MARKER" ]; then
  echo "devflow: describe-defer-probe.sh: needs <hook-fired-marker> <tool-ran-marker> — rendering nothing" >&2
  exit 0
fi

_DDP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-jq.sh
. "$_DDP_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: describe-defer-probe.sh: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
if [ -z "${DEVFLOW_JQ:-}" ]; then
  DEVFLOW_JQ=jq
fi
# shellcheck source=../lib/probe-observation.sh
if ! . "$_DDP_DIR/../lib/probe-observation.sh" 2>/dev/null \
   || ! type devflow_probe_exec_state >/dev/null 2>&1; then
  echo "devflow: describe-defer-probe.sh: lib/probe-observation.sh not sourceable — every execution-file axis renders unavailable" >&2
  devflow_probe_exec_state() { printf '%s\n' unavailable; }
  devflow_probe_cli_version() { printf '%s\n' unavailable; }
  devflow_probe_transcript_has() { printf '%s\n' unavailable; }
  devflow_probe_tooluse_has() { printf '%s\n' unavailable; }
  devflow_probe_denials_count() { printf '%s\n' unavailable; }
  devflow_probe_denials_have() { printf '%s\n' unavailable; }
fi

echo "## PreToolUse \`defer\` fall-through probe (Bash)"
echo "- observed CLI version: \`$(devflow_probe_cli_version "$EXECUTION_FILE")\`"

# ── Axis 1 (PRIMARY, breadcrumb-only): did the hook run? ─────────────────────
if [ -e "$HOOK_MARKER" ]; then
  echo "- hook firing: **FIRED** — the \`defer\`-emitting PreToolUse hook ran (breadcrumb \`$HOOK_MARKER\` present)."
  HOOK_FIRED=yes
else
  echo "- hook firing: **NOT-FIRED** — no breadcrumb at \`$HOOK_MARKER\` (an established negative: the probe checked)."
  HOOK_FIRED=no
fi

# ── Axis 2 (PRIMARY, breadcrumb-only): did the tool run anyway? ──────────────
if [ "$HOOK_FIRED" = no ]; then
  echo "- \`defer\` behavior: **UNESTABLISHED** — the hook never ran, so nothing was deferred and this run measures neither outcome."
elif [ -e "$TOOL_MARKER" ]; then
  echo "- \`defer\` behavior: **DEFER-FELL-THROUGH** — the granted command's side effect \`$TOOL_MARKER\` is present, so a \`defer\` DID fall through to the default permission flow and the tool executed."
else
  echo "- \`defer\` behavior: **DEFER-BLOCKED** — the hook fired and the granted command's side effect \`$TOOL_MARKER\` is absent, so the tool did NOT execute: \`defer\` is not a fall-through here."
fi

# ── Axis 3 (SECONDARY): the documented `tool_deferred` stop reason. ──────────
# A honored defer may destroy the execution file, so `unavailable` here is an
# expected, non-contradicting reading — never evidence against Axis 2.
case "$(devflow_probe_transcript_has "$EXECUTION_FILE" "$DFR_STOP_REASON")" in
  yes) echo "- stop reason (secondary): **STOP-REASON-DEFERRED** — the transcript carries \`$DFR_STOP_REASON\`, corroborating a honored defer." ;;
  no)  echo "- stop reason (secondary): **STOP-REASON-NOT-DEFERRED** — the transcript parsed cleanly and carries no \`$DFR_STOP_REASON\`." ;;
  *)   echo "- stop reason (secondary): **unavailable** (execution file absent, empty, unparseable, or jq not runnable). On this arm that is an EXPECTED reading if the defer was honored — it neither confirms nor contradicts the breadcrumb verdict above." ;;
esac

# ── Axis 4 (SECONDARY): was the command recorded at all, and were there denials?
# Scoped to TOOL-CALL INPUTS, never the transcript at large: the transcript carries
# the prompt, which quotes this very command, so an any-string search would report
# "issued" for a session that never issued it.
COMMAND_SEEN="$(devflow_probe_tooluse_has "$EXECUTION_FILE" "$DFR_COMMAND_TOKEN")"
echo "- command issued (secondary): **$COMMAND_SEEN** (yes = a recorded tool-call input carries it; no = tool-call inputs were recorded and none does; unavailable = could not check)"
echo "- \`permission_denials\` entries (secondary): **$(devflow_probe_denials_count "$EXECUTION_FILE")** (a count, or \`unavailable\` when the array could not be read — never collapsed onto 0)"

exit 0
