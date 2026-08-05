#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-pretooluse-deny-probe.sh — render the `pretooluse-deny-probe`
# observation for matcher-probe.yml's step summary.
#
# THE QUESTION. The existing `pretooluse-probe` arm emits
# `permissionDecision: "allow"`, and for an `allow` the published contract states
# `permissionDecisionReason` is IGNORED — so every observation that arm has ever
# produced says nothing about whether a reason reaches anything on the DENY path.
# This arm emits a real `deny` with a distinctive reason sentinel on a sacrificial
# command and measures whether that reason is delivered.
#
# WHY IT IS A SEPARATE JOB FROM `permissionrequest-probe`. `PreToolUse` runs
# BEFORE the permission system: a `PreToolUse` deny resolves the call, so a
# `PermissionRequest` hook would never fire and would be recorded as a false
# "not fired"; and a `PreToolUse` allow would rescue that probe's ungranted arm and
# destroy the discrimination it exists for. The two hooks therefore never share a
# session.
#
# Usage:
#   describe-pretooluse-deny-probe.sh <fired-marker> <denied-marker> \
#                                     <sacrificial-marker> <control-marker> \
#                                     [execution-file]
#     fired-marker        written by the hook on EVERY invocation.
#     denied-marker       written by the hook only on its deny arm — the hook is
#                         command-scoped, so this separates "the hook ran" from
#                         "the hook denied".
#     sacrificial-marker  the on-disk side effect the sacrificial command would
#                         produce IF it executed. Its ABSENCE is the deny working.
#     control-marker      the on-disk side effect of the granted control command
#                         the hook must not touch.
#     execution-file      claude-code-action's execution_file output (optional) —
#                         the SECONDARY axis only.
#
# Best-effort: always exits 0; a missing required argument breadcrumbs to stderr
# and renders nothing.
#
# COUPLED SITE — the constants below are one contract with the
# `pretooluse-deny-probe` job in .github/workflows/matcher-probe.yml (the tokens
# are substrings of the commands its prompt dictates and of its hook's own
# command-scoping pattern; the sentinel is the reason the hook emits). Edit both
# together.

set -uo pipefail

# Substring of the SACRIFICIAL command — also the hook's own scoping pattern, so
# the hook cannot touch any other command in the session.
PTUD_SACRIFICIAL_TOKEN="ptudprobe-sacrificial"
# Substring of the GRANTED control command the hook must leave alone.
PTUD_CONTROL_TOKEN="ptudprobe-control-ran"
# The `permissionDecisionReason` the probe's deny carries.
PTUD_SENTINEL="devflow pretooluse-deny-probe: PTUD-DENY-SENTINEL"

FIRED_MARKER="${1:-}"
DENIED_MARKER="${2:-}"
SACRIFICIAL_MARKER="${3:-}"
CONTROL_MARKER="${4:-}"
EXECUTION_FILE="${5:-}"

if [ -z "$FIRED_MARKER" ] || [ -z "$DENIED_MARKER" ] || [ -z "$SACRIFICIAL_MARKER" ] || [ -z "$CONTROL_MARKER" ]; then
  echo "devflow: describe-pretooluse-deny-probe.sh: needs <fired-marker> <denied-marker> <sacrificial-marker> <control-marker> — rendering nothing" >&2
  exit 0
fi

_DPD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-jq.sh
. "$_DPD_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: describe-pretooluse-deny-probe.sh: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
if [ -z "${DEVFLOW_JQ:-}" ]; then
  DEVFLOW_JQ=jq
fi
# shellcheck source=../lib/probe-observation.sh
if ! . "$_DPD_DIR/../lib/probe-observation.sh" 2>/dev/null \
   || ! type devflow_probe_exec_state >/dev/null 2>&1; then
  echo "devflow: describe-pretooluse-deny-probe.sh: lib/probe-observation.sh not sourceable — every execution-file axis renders unavailable" >&2
  devflow_probe_exec_state() { printf '%s\n' unavailable; }
  devflow_probe_cli_version() { printf '%s\n' unavailable; }
  devflow_probe_transcript_has() { printf '%s\n' unavailable; }
  devflow_probe_tooluse_has() { printf '%s\n' unavailable; }
  devflow_probe_denials_count() { printf '%s\n' unavailable; }
  devflow_probe_denials_have() { printf '%s\n' unavailable; }
fi

echo "## PreToolUse deny-path probe (Bash)"
echo "- observed CLI version: \`$(devflow_probe_cli_version "$EXECUTION_FILE")\`"

# ── Axis 1 (PRIMARY, breadcrumb-first): did the hook run, and did it deny? ─────
if [ -e "$FIRED_MARKER" ]; then
  if [ -e "$DENIED_MARKER" ]; then
    echo "- hook firing: **FIRED-AND-DENIED** — the hook ran and took its deny arm (breadcrumbs \`$FIRED_MARKER\` and \`$DENIED_MARKER\` present)."
  else
    echo "- hook firing: **FIRED-WITHOUT-DENY** — the hook ran but never took its deny arm (\`$DENIED_MARKER\` absent); the sacrificial command never reached it."
  fi
else
  echo "- hook firing: **NOT-FIRED** — the probe checked \`$FIRED_MARKER\` and found no breadcrumb. The hook writes it best-effort (its own \`mkdir -p\` can fail), so this does not by itself separate \"the hook never fired\" from \"it fired and could not record it\"; the axes below are what establish or decline the deny verdict."
fi

# ── Axis 2 (PRIMARY): was the deny actually honored? ──────────────────────────
# The attempt reads scan TOOL-CALL INPUTS, never the transcript at large: the
# transcript carries the prompt, which quotes every one of these command tokens.
SACRIFICIAL_ATTEMPTED="$(devflow_probe_tooluse_has "$EXECUTION_FILE" "$PTUD_SACRIFICIAL_TOKEN")"
if [ -e "$SACRIFICIAL_MARKER" ]; then
  echo "- deny honored: **DENY-NOT-HONORED** — the sacrificial command's side effect \`$SACRIFICIAL_MARKER\` is present, so the tool ran despite the hook's deny."
elif [ -e "$DENIED_MARKER" ]; then
  echo "- deny honored: **DENY-HONORED** — the hook took its deny arm and the sacrificial command's side effect \`$SACRIFICIAL_MARKER\` is absent."
else
  case "$SACRIFICIAL_ATTEMPTED" in
    yes) echo "- deny honored: **unavailable** — the transcript records the sacrificial command and its side effect is absent, but the hook's deny arm left no breadcrumb, so the absence is not attributable to the deny." ;;
    no)  echo "- deny honored: **UNATTEMPTED** — no side effect and no trace of the sacrificial command in the transcript: the session never issued it, so this arm measured nothing." ;;
    *)   echo "- deny honored: **unavailable** — no side effect, no deny breadcrumb, and the execution file could not be read: \"denied\" and \"never attempted\" cannot be separated." ;;
  esac
fi

# ── Axis 3: did the hook leave the GRANTED control alone? ─────────────────────
CONTROL_ATTEMPTED="$(devflow_probe_tooluse_has "$EXECUTION_FILE" "$PTUD_CONTROL_TOKEN")"
if [ -e "$CONTROL_MARKER" ]; then
  echo "- granted control: **CONTROL-RAN** — the command-scoped hook left the granted control untouched (\`$CONTROL_MARKER\` present)."
else
  case "$CONTROL_ATTEMPTED" in
    yes) echo "- granted control: **CONTROL-BLOCKED** — the transcript records the granted control but its side effect \`$CONTROL_MARKER\` is absent: the hook's scoping did not hold." ;;
    no)  echo "- granted control: **CONTROL-UNATTEMPTED** — no side effect and no trace in the transcript: the session never issued it." ;;
    *)   echo "- granted control: **unavailable** — side effect absent and the execution file could not be read, so \"blocked\" and \"never attempted\" cannot be separated." ;;
  esac
fi

# ── Axis 4: does the deny REASON reach the engine transcript? (the arm the
#    allow-only `pretooluse-probe` structurally cannot answer) ────────────────
case "$(devflow_probe_transcript_has "$EXECUTION_FILE" "$PTUD_SENTINEL")" in
  yes) echo "- deny reason in transcript: **REASON-DELIVERED** — a string carrying the probe's deny-reason sentinel was found in the execution transcript." ;;
  no)  echo "- deny reason in transcript: **REASON-ABSENT** — the transcript parsed cleanly and carries no string with the probe's deny-reason sentinel." ;;
  *)   echo "- deny reason in transcript: **unavailable** (execution file absent, empty, unparseable, or jq not runnable — could not check)" ;;
esac

# ── Axis 5 (cross-cutting): is a HOOK-issued deny visible in
#    `permission_denials`? If not, a production hook deny would drop the published
#    denial count while the measurement silently stopped.
DEN_COUNT="$(devflow_probe_denials_count "$EXECUTION_FILE")"
DENY_ARM=no
[ -e "$DENIED_MARKER" ] && DENY_ARM=yes
case "$(devflow_probe_denials_have "$EXECUTION_FILE" "$PTUD_SENTINEL"):$DENY_ARM" in
  yes:*)
    echo "- hook deny in \`permission_denials\`: **HOOK-DENY-RECORDED** — a denials entry carries the hook's own sentinel (count: $DEN_COUNT)." ;;
  no:yes)
    echo "- hook deny in \`permission_denials\`: **HOOK-DENY-NOT-RECORDED** — the hook took its deny arm, the denials array parsed cleanly, and no entry carries its sentinel (count: $DEN_COUNT). A production hook deny would therefore be invisible to any denial-count measurement." ;;
  no:*)
    echo "- hook deny in \`permission_denials\`: **NOT-APPLICABLE** — the denials array parsed cleanly and carries no hook sentinel (count: $DEN_COUNT), but the hook never took its deny arm, so there was no hook deny to record and this arm measured nothing." ;;
  *)
    echo "- hook deny in \`permission_denials\`: **unavailable** (count: $DEN_COUNT) — the denials array could not be read (absent from the execution file, unparseable, or jq not runnable), so this is not an established negative." ;;
esac
# The sentinel axis alone cannot separate "the hook deny produced no denials entry
# at all" from "it produced one that simply does not carry the reason text" — and
# those have opposite consequences for a denial-count measurement. So the COMMAND
# is looked for in the array too. (This job hit exactly that shape on live run
# 30966800385 — no sentinel, count 1. A matcher-probe run id names a whole workflow
# run rather than one job, so sibling renderers correctly cite the same id for
# their own arms: in that run the `permissionrequest-probe` job separately recorded
# a non-firing hook and zero denials.)
case "$(devflow_probe_denials_have "$EXECUTION_FILE" "$PTUD_SACRIFICIAL_TOKEN")" in
  yes) echo "- denied command in \`permission_denials\`: **COMMAND-RECORDED** — a denials entry names the sacrificial command, so the hook's deny IS visible to a denial-count measurement even though the array carries no reason text." ;;
  no)  echo "- denied command in \`permission_denials\`: **COMMAND-NOT-RECORDED** — the denials array parsed cleanly and no entry names the sacrificial command." ;;
  *)   echo "- denied command in \`permission_denials\`: **unavailable** — the denials array is absent from the execution file, or could not be read." ;;
esac

exit 0
