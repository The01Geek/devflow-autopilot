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
# WHY THERE ARE TWO GRANTED CONTROLS. The arm is only exercised if the session
# actually ISSUES the ungranted command, and a model that decides for itself that
# a command will be refused, and answers without issuing it, produces a run that
# looks exactly like "the hook did not fire" (observed in THIS job on the probe's
# first live run, 30966800385: one tool call, zero denials — a matcher-probe run id
# names a whole workflow run, so sibling probe renderers cite the same id for their
# own jobs' arms). The second control runs AFTER the ungranted command, so a run in
# which it executed while nothing was ever refused is attributable to the model
# having SKIPPED the arm, rather than left as an ambiguous negative.
#
# Usage:
#   describe-permissionrequest-probe.sh <seen-file> <control-marker> \
#                                       <ungranted-marker> <after-marker> \
#                                       [execution-file]
#     seen-file        the JSONL breadcrumb the probe's PermissionRequest hook
#                      appends its raw stdin payload to on every invocation. The
#                      payload carries the tool input, so the file's CONTENT — not
#                      merely its existence — is what attributes the firing to the
#                      granted or the ungranted command.
#     control-marker   the on-disk side effect the GRANTED control command
#                      produces when it actually executes.
#     ungranted-marker the on-disk side effect the UNGRANTED command produces if it
#                      executes anyway. Its presence is the only thing that
#                      separates "the harness refused the call" from "the harness
#                      allowed it" — the second live run (30967286749) issued the
#                      ungranted command, got past it, and recorded ZERO
#                      permission_denials, so absence-of-a-denial cannot carry that
#                      distinction on its own.
#     after-marker     the on-disk side effect of the second granted control, which
#                      the prompt places AFTER the ungranted command.
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
PRQ_UNGRANTED_TOKEN="prqprobe-ungranted-ran"
# (The second granted control carries no token constant: it is identified by the
# marker PATH the caller passes, since nothing about it needs recognising inside a
# transcript.)
# The `message` the probe's deny decision carries.
PRQ_SENTINEL="devflow permissionrequest-probe: PRQ-DENY-SENTINEL"

SEEN="${1:-}"
CONTROL_MARKER="${2:-}"
UNGRANTED_MARKER="${3:-}"
AFTER_MARKER="${4:-}"
EXECUTION_FILE="${5:-}"

if [ -z "$SEEN" ] || [ -z "$CONTROL_MARKER" ] || [ -z "$UNGRANTED_MARKER" ] || [ -z "$AFTER_MARKER" ]; then
  echo "devflow: describe-permissionrequest-probe.sh: needs <seen-file> <control-marker> <ungranted-marker> <after-marker> — rendering nothing" >&2
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
  devflow_probe_tooluse_has() { printf '%s\n' unavailable; }
  devflow_probe_denials_count() { printf '%s\n' unavailable; }
  devflow_probe_denials_have() { printf '%s\n' unavailable; }
fi

echo "## PermissionRequest hook probe (Bash)"
echo "- observed CLI version: \`$(devflow_probe_cli_version "$EXECUTION_FILE")\`"

# ── Axis 1 (PRIMARY, breadcrumb-first): did the hook fire, and on WHICH call? ──
SAW_GRANTED=no
SAW_UNGRANTED=no
if [ -f "$SEEN" ] && [ -s "$SEEN" ]; then
  # Builtin-only scan. These two flags SELECT the emitted Axis-1 verdict and the
  # Axis-5 inference, so per CLAUDE.md they must not be derived through a
  # non-preflight PATH tool: an absent `grep` would leave both `no` and publish
  # FIRED-UNATTRIBUTED over a breadcrumb that did carry a token. The `|| [ -n … ]`
  # tail picks up a final line the hook wrote without a trailing newline.
  while IFS= read -r _prq_line || [ -n "$_prq_line" ]; do
    case "$_prq_line" in *"$PRQ_GRANTED_TOKEN"*) SAW_GRANTED=yes ;; esac
    case "$_prq_line" in *"$PRQ_UNGRANTED_TOKEN"*) SAW_UNGRANTED=yes ;; esac
  done < "$SEEN"
  FIRED=yes
else
  FIRED=no
fi

case "$FIRED:$SAW_GRANTED:$SAW_UNGRANTED" in
  no:*)
    echo "- hook firing: **NOT-FIRED** — the probe checked \`$SEEN\` and the hook wrote no breadcrumb there. The hook writes it best-effort (its own \`mkdir -p\` can fail), so this does not by itself separate \"the hook never fired\" from \"it fired and could not record it\" — see the inference line below, which is where that separation is established or declared UNESTABLISHED."
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
# The attempt reads scan TOOL-CALL INPUTS, never the transcript at large: the
# transcript carries the prompt, which quotes every one of these command tokens.
CONTROL_ATTEMPTED="$(devflow_probe_tooluse_has "$EXECUTION_FILE" "$PRQ_GRANTED_TOKEN")"
if [ -e "$CONTROL_MARKER" ]; then
  echo "- granted control: **CONTROL-RAN** — its side effect \`$CONTROL_MARKER\` is present, so the granted command executed."
else
  case "$CONTROL_ATTEMPTED" in
    yes) echo "- granted control: **CONTROL-BLOCKED** — the transcript records the granted command but its side effect \`$CONTROL_MARKER\` is absent: it was attempted and did not execute." ;;
    no)  echo "- granted control: **CONTROL-UNATTEMPTED** — no side effect and no trace of the command in the transcript: the session never issued it, so this arm measured nothing." ;;
    *)   echo "- granted control: **unavailable** — side effect \`$CONTROL_MARKER\` absent, and the execution file could not be read, so \"blocked\" and \"never attempted\" cannot be separated." ;;
  esac
fi

# ── Axis 2b: was the UNGRANTED command actually issued, and did the session get
#    PAST it? Without these the whole arm is unfalsifiable: a model that decides
#    for itself not to issue a command it expects to be refused produces a run
#    indistinguishable from "the hook did not fire".
UNGRANTED_ATTEMPTED="$(devflow_probe_tooluse_has "$EXECUTION_FILE" "$PRQ_UNGRANTED_TOKEN")"
case "$UNGRANTED_ATTEMPTED" in
  yes) echo "- ungranted arm attempt: **ATTEMPTED** — a recorded tool-call input carries the ungranted command, so the arm really was exercised." ;;
  no)  echo "- ungranted arm attempt: **NOT-ATTEMPTED** — tool-call inputs were recorded and none carries the ungranted command: the session never issued it, so the arm was not exercised." ;;
  *)   echo "- ungranted arm attempt: **unavailable** — no tool-call inputs could be read, so \"issued\" and \"never issued\" cannot be separated." ;;
esac

# ── Axis 2c (PRIMARY): was the ungranted command REFUSED, or simply ALLOWED? ──
# An absent `permission_denials` entry cannot answer this: the second live run
# issued the ungranted command, reached past it, and recorded ZERO denials — which
# is consistent both with a silent refusal and with the harness allowing the call
# outright. Only the command's own side effect separates them, and the difference
# is decisive: if the call was allowed, the allowlist declined nothing and NO call
# was ever offered to a canUseTool-slot hook, so a non-firing hook says nothing
# about the event's existence.
if [ -e "$UNGRANTED_MARKER" ]; then
  UNGRANTED_OUTCOME=executed
  echo "- ungranted arm outcome: **UNGRANTED-EXECUTED** — the ungranted command's side effect \`$UNGRANTED_MARKER\` is present, so the harness ALLOWED it: nothing was declined on this run."
elif [ "$UNGRANTED_ATTEMPTED" = yes ]; then
  UNGRANTED_OUTCOME=refused
  echo "- ungranted arm outcome: **UNGRANTED-REFUSED** — the command was issued and its side effect \`$UNGRANTED_MARKER\` is absent, so the harness refused it: a call the allowlist did not resolve really did reach the permission system."
elif [ "$UNGRANTED_ATTEMPTED" = no ]; then
  UNGRANTED_OUTCOME=unattempted
  echo "- ungranted arm outcome: **NOT-EXERCISED** — the command was never issued, so there is nothing to refuse or allow."
else
  UNGRANTED_OUTCOME=unavailable
  echo "- ungranted arm outcome: **unavailable** — no side effect, and whether the command was issued could not be read, so \"refused\" and \"never issued\" cannot be separated."
fi
if [ -e "$AFTER_MARKER" ]; then
  echo "- post-arm control: **AFTER-CONTROL-RAN** — the granted command placed AFTER the ungranted one executed (\`$AFTER_MARKER\` present), so the session reached past the arm."
  AFTER_RAN=yes
else
  echo "- post-arm control: **AFTER-CONTROL-ABSENT** — the granted command placed after the ungranted one left no side effect, so the session did not demonstrably get past the arm."
  AFTER_RAN=no
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
    echo "- hook deny in \`permission_denials\`: **unavailable** (count: $DEN_COUNT) — the denials array could not be read (absent from the execution file, unparseable, or jq not runnable), so this is not an established negative." ;;
esac
echo "- ungranted arm in \`permission_denials\`: **$DEN_UNGRANTED** (yes = the matcher refused it and said so; no = the array was there and carries no such entry; unavailable = no such array exists, or it could not be read)"

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
elif [ "$UNGRANTED_OUTCOME" = refused ]; then
  # The decisive negative. Note it does NOT depend on permission_denials: a refusal
  # the array never recorded is still a refusal, and the second live run showed the
  # array can stay empty across one.
  printf '%s' "a call the allowlist did not resolve DID reach the permission system and was REFUSED, yet no hook breadcrumb exists — so this is evidence that the installed CLI does not deliver a \`PermissionRequest\` event, NOT merely that nothing reached it."
  if [ "$DEN_COUNT" = 0 ]; then
    echo " (Separately: that refusal left no \`permission_denials\` entry either, so the array under-reports refusals in this configuration.)"
  else
    echo ""
  fi
elif [ "$UNGRANTED_OUTCOME" = executed ]; then
  echo "the ungranted command EXECUTED, so the harness declined nothing on this run and no call was ever offered to a \`canUseTool\`-slot hook. A non-firing hook therefore says nothing about the event's existence: UNESTABLISHED, not negative. The arm needs a command this configuration actually refuses."
elif [ "$UNGRANTED_OUTCOME" = unattempted ]; then
  echo "no breadcrumb, and no recorded tool call carries the ungranted command — the SESSION SKIPPED the arm rather than the harness refusing it$([ "$AFTER_RAN" = yes ] && printf '%s' ' (the control placed after the arm did run, so the session reached past it)'). Nothing was ever offered to a \`PermissionRequest\` hook: the event's availability is UNESTABLISHED, not negative. Re-run with a prompt the model actually obeys."
elif [ "$DEN_UNGRANTED" = yes ] || { [ "$DEN_COUNT" != unavailable ] && [ "$DEN_COUNT" != 0 ]; }; then
  echo "a call DID reach the permission system and was refused (it is in \`permission_denials\`), yet no hook breadcrumb exists — so this is evidence that the installed CLI does not deliver a \`PermissionRequest\` event, NOT merely that nothing reached it."
else
  # Reaching here means UNGRANTED_ATTEMPTED was `unavailable` — which happens only
  # for reasons that are NEEDLE-INDEPENDENT (unreadable/unparseable execution file,
  # jq not runnable, or no tool-call inputs recorded at all). CONTROL_ATTEMPTED is
  # read from the same file by the same function, so it is `unavailable` here too:
  # do not add an arm keyed on it reading `no`, which cannot occur on this path.
  echo "no breadcrumb, and the run's own record could not be read well enough to say whether anything was refused — \"the event is absent\" cannot be separated from \"nothing reached it\". UNESTABLISHED; re-run the probe."
fi

exit 0
