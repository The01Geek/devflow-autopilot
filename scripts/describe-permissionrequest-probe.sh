#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-permissionrequest-probe.sh — render the `permissionrequest-probe`
# observation for matcher-probe.yml's step summary.
#
# THE QUESTION. The Agent SDK type contract the action depends on publishes a
# `PermissionRequest` hook whose output is a decision object
# (`{behavior:"allow"…}` / `{behavior:"deny",message?…}`). Two things about it are
# unestablished for the CLI `anthropics/claude-code-action@v1` actually installs:
#
#   (a) does the event fire at all, and
#   (b) WHICH calls reach it.
#
# (b) is why this probe exists. The published six-step permission order — hooks,
# deny rules, ask rules, permission mode, allow rules, canUseTool — does not
# mention `PermissionRequest` anywhere. If it occupies the `canUseTool` slot it
# sees only calls the allowlist did NOT resolve, and an unconditional-deny hook is
# harmless to granted work. If it resolves EARLIER it also sees calls the
# allowlist would have approved, and such a hook silently blocks granted work.
# The probe therefore attempts a GRANTED CONTROL command alongside the ungranted
# one and reports which of the two the hook saw. That discrimination is this
# renderer's primary output.
#
# Usage:
#   describe-permissionrequest-probe.sh <seen-file> <control-marker> [execution-file]
#     seen-file        the JSONL breadcrumb the probe's PermissionRequest hook
#                      appends its raw stdin payload to on every invocation. The
#                      payload carries the tool input, so the file's CONTENT — not
#                      merely its existence — is what attributes the firing to the
#                      granted or the ungranted command.
#     control-marker   the on-disk side effect the GRANTED control command
#                      produces when it actually executes.
#     execution-file   claude-code-action's execution_file output (optional). It is
#                      the SECONDARY axis only: its absence degrades a secondary
#                      verdict to `unavailable`, never to an established negative.
#
# Best-effort: always exits 0 (an informational renderer must not fail the probe
# job); a missing required argument breadcrumbs to stderr and renders nothing.
#
# COUPLED SITE — the three constants below are one contract with the
# `permissionrequest-probe` job in .github/workflows/matcher-probe.yml: the tokens
# are substrings of the two commands that job's prompt dictates, and the sentinel
# is the `message` its hook emits. Edit both together (same discipline as
# scripts/background-tasks-probe-verdict.py's marker vocabulary).

set -uo pipefail

# Substring of the GRANTED control command the probe prompt dictates.
PRQ_GRANTED_TOKEN="prqprobe-control-ran"
# Substring of the UNGRANTED command the probe prompt dictates (its head is in no
# allowlist, so the matcher must refuse it).
PRQ_UNGRANTED_TOKEN="prqprobe-ungranted-token"
# The `message` the probe's deny decision carries.
PRQ_SENTINEL="devflow permissionrequest-probe: PRQ-DENY-SENTINEL"

SEEN="${1:-}"
CONTROL_MARKER="${2:-}"
EXECUTION_FILE="${3:-}"

if [ -z "$SEEN" ] || [ -z "$CONTROL_MARKER" ]; then
  echo "devflow: describe-permissionrequest-probe.sh: needs <seen-file> <control-marker> — rendering nothing" >&2
  exit 0
fi

_DPR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-jq.sh
. "$_DPR_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: describe-permissionrequest-probe.sh: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
if [ -z "${DEVFLOW_JQ:-}" ]; then
  DEVFLOW_JQ=jq
fi
# shellcheck source=../lib/probe-observation.sh
if ! . "$_DPR_DIR/../lib/probe-observation.sh" 2>/dev/null \
   || ! type devflow_probe_exec_state >/dev/null 2>&1; then
  # A partially-copied deployment must degrade to "unestablished", never to a
  # confident negative — so stub every reader to `unavailable`.
  echo "devflow: describe-permissionrequest-probe.sh: lib/probe-observation.sh not sourceable — every execution-file axis renders unavailable" >&2
  devflow_probe_exec_state() { printf '%s\n' unavailable; }
  devflow_probe_cli_version() { printf '%s\n' unavailable; }
  devflow_probe_transcript_has() { printf '%s\n' unavailable; }
  devflow_probe_denials_count() { printf '%s\n' unavailable; }
  devflow_probe_denials_have() { printf '%s\n' unavailable; }
fi

echo "## PermissionRequest hook probe (Bash)"
echo "- observed CLI version: \`$(devflow_probe_cli_version "$EXECUTION_FILE")\`"

# ── Axis 1 (PRIMARY, breadcrumb-first): did the hook fire, and on WHICH call? ──
SAW_GRANTED=no
SAW_UNGRANTED=no
if [ -f "$SEEN" ] && [ -s "$SEEN" ]; then
  grep -qF -- "$PRQ_GRANTED_TOKEN" "$SEEN" 2>/dev/null && SAW_GRANTED=yes
  grep -qF -- "$PRQ_UNGRANTED_TOKEN" "$SEEN" 2>/dev/null && SAW_UNGRANTED=yes
  FIRED=yes
else
  FIRED=no
fi

case "$FIRED:$SAW_GRANTED:$SAW_UNGRANTED" in
  no:*)
    echo "- hook firing: **NOT-FIRED** — the hook wrote no breadcrumb at \`$SEEN\` (an established negative: the probe checked)."
    ;;
  yes:yes:yes)
    echo "- hook firing: **HOOK-SAW-BOTH** — the breadcrumb records BOTH the granted control command and the ungranted one."
    ;;
  yes:yes:no)
    echo "- hook firing: **HOOK-SAW-GRANTED-CONTROL** — the breadcrumb records the granted control command."
    ;;
  yes:no:yes)
    echo "- hook firing: **HOOK-SAW-UNGRANTED-ONLY** — the breadcrumb records the ungranted command and NOT the granted control."
    ;;
  *)
    echo "- hook firing: **FIRED-UNATTRIBUTED** — a breadcrumb exists at \`$SEEN\` but carries neither command token; the firing is real, the attribution is not established."
    ;;
esac

# ── Axis 2: did the GRANTED control actually execute? ─────────────────────────
# Marker-first. When the marker is absent the execution file separates "attempted
# and blocked" from "never attempted" — two different facts that must not collapse.
CONTROL_ATTEMPTED="$(devflow_probe_transcript_has "$EXECUTION_FILE" "$PRQ_GRANTED_TOKEN")"
if [ -e "$CONTROL_MARKER" ]; then
  echo "- granted control: **CONTROL-RAN** — its side effect \`$CONTROL_MARKER\` is present, so the granted command executed."
else
  case "$CONTROL_ATTEMPTED" in
    yes) echo "- granted control: **CONTROL-BLOCKED** — the transcript records the granted command but its side effect \`$CONTROL_MARKER\` is absent: it was attempted and did not execute." ;;
    no)  echo "- granted control: **CONTROL-UNATTEMPTED** — no side effect and no trace of the command in the transcript: the session never issued it, so this arm measured nothing." ;;
    *)   echo "- granted control: **unavailable** — side effect \`$CONTROL_MARKER\` absent, and the execution file could not be read, so \"blocked\" and \"never attempted\" cannot be separated." ;;
  esac
fi

# ── Axis 3 (c): does the deny `message` reach the engine transcript? ───────────
case "$(devflow_probe_transcript_has "$EXECUTION_FILE" "$PRQ_SENTINEL")" in
  yes) echo "- deny message in transcript: **SENTINEL-DELIVERED** — a string carrying the probe's \`message\` sentinel was found in the execution transcript." ;;
  no)  echo "- deny message in transcript: **SENTINEL-ABSENT** — the transcript parsed cleanly and carries no string with the probe's \`message\` sentinel." ;;
  *)   echo "- deny message in transcript: **unavailable** (execution file absent, empty, unparseable, or jq not runnable — could not check)" ;;
esac

# ── Axis 4 (cross-cutting): is a HOOK-issued deny still visible in
#    `permission_denials`? If it is not, wiring such a hook in production would
#    make the published denial count fall while the measurement silently stopped —
#    an improvement-shaped regression. Measured here rather than discovered later.
DEN_COUNT="$(devflow_probe_denials_count "$EXECUTION_FILE")"
DEN_SENTINEL="$(devflow_probe_denials_have "$EXECUTION_FILE" "$PRQ_SENTINEL")"
DEN_UNGRANTED="$(devflow_probe_denials_have "$EXECUTION_FILE" "$PRQ_UNGRANTED_TOKEN")"
case "$DEN_SENTINEL:$FIRED" in
  yes:*)
    echo "- hook deny in \`permission_denials\`: **HOOK-DENY-RECORDED** — a denials entry carries the hook's own sentinel (count: $DEN_COUNT)." ;;
  no:yes)
    # The hook denies unconditionally, so a firing IS a hook deny: its absence from
    # the array is then a real measurement, not a vacuous one.
    echo "- hook deny in \`permission_denials\`: **HOOK-DENY-NOT-RECORDED** — the hook fired (and this hook always denies), the denials array parsed cleanly, and no entry carries its sentinel (count: $DEN_COUNT). A production hook deny would therefore be invisible to any denial-count measurement." ;;
  no:*)
    echo "- hook deny in \`permission_denials\`: **NOT-APPLICABLE** — the denials array parsed cleanly and carries no hook sentinel (count: $DEN_COUNT), but the hook never fired, so there was no hook deny to record and this arm measured nothing." ;;
  *)
    echo "- hook deny in \`permission_denials\`: **unavailable** (count: $DEN_COUNT) — could not read the denials array, so this is not an established negative." ;;
esac
echo "- ungranted arm in \`permission_denials\`: **$DEN_UNGRANTED** (yes = the matcher refused it and said so; no = it parsed cleanly and carries no such entry; unavailable = could not check)"

# ── Axis 5: the explicit inference — "event absent" vs "nothing reached it". ───
# A breadcrumb-free run means two very different things depending on whether ANY
# call actually reached the permission system, so the distinguishing statement is
# emitted rather than left for a reader to reconstruct.
printf '%s' "- inference: "
if [ "$FIRED" = yes ] && [ "$SAW_GRANTED" = yes ]; then
  echo "the \`PermissionRequest\` event FIRES and it sees calls the allowlist would have approved — it does NOT sit at the \`canUseTool\` slot. An unconditional-deny hook would block granted work; a production hook must be command-scoped, not blanket."
elif [ "$FIRED" = yes ] && [ "$SAW_UNGRANTED" = yes ]; then
  echo "the \`PermissionRequest\` event FIRES and, on this run, saw ONLY the call the allowlist did not resolve — consistent with the \`canUseTool\` slot, under which an unconditional-deny hook leaves granted work untouched. Scoped to this CLI version and to the two commands attempted."
elif [ "$FIRED" = yes ]; then
  echo "the \`PermissionRequest\` event FIRES, but neither command token was recoverable from the breadcrumb, so WHICH calls reach it is not established by this run."
elif [ "$DEN_UNGRANTED" = yes ] || { [ "$DEN_COUNT" != unavailable ] && [ "$DEN_COUNT" != 0 ]; }; then
  echo "a call DID reach the permission system and was refused (it is in \`permission_denials\`), yet no hook breadcrumb exists — so this is evidence that the installed CLI does not deliver a \`PermissionRequest\` event, NOT merely that nothing reached it."
elif [ "$DEN_COUNT" = 0 ] && [ "$CONTROL_ATTEMPTED" = no ]; then
  echo "no breadcrumb, no denials and no trace of the control command — nothing reached the permission system at all (the session may have failed before issuing any tool call, e.g. if the \`settings\` input was rejected). The event's availability is UNESTABLISHED, not negative."
elif [ "$DEN_COUNT" = 0 ]; then
  echo "no breadcrumb and zero denials, though the transcript is readable — no call was refused, so nothing was ever offered to a \`PermissionRequest\` hook. The event's availability is UNESTABLISHED, not negative."
else
  echo "no breadcrumb, and the execution file could not be read — \"the event is absent\" cannot be separated from \"nothing reached it\". UNESTABLISHED; re-run the probe."
fi

exit 0
