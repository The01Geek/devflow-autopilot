#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-pretooluse-probe.sh — render the AC7 PreToolUse settings-input probe
# observation for matcher-probe.yml's `pretooluse-probe` job step summary (issue #908).
# A new file rather than an extension of describe-hook-probe.sh: that helper's report
# shape is a single FIRED/NOT-FIRED axis over a base-branch `.claude/settings.json`
# Stop hook, whereas this probe additionally measures whether the settings-input
# mechanism itself delivers a PreToolUse hook AND whether a permissionDecisionReason
# it emits reaches the execution transcript — a second, independent axis with its own
# distinct unavailable state (a probe-report shape genuinely different from the
# single-axis original, per the 2.2.4 reuse-and-altitude call: extend only when the
# shapes are compatible).
#
# Usage: describe-pretooluse-probe.sh <marker-path> [execution-file-path]
#   marker-path          the `.prflow/tmp/pretooluse-probe-fired` breadcrumb the
#                         probe's ad hoc settings-input hook writes on firing.
#   execution-file-path   claude-code-action's execution_file output (optional — its
#                         absence degrades reason-delivery to "unavailable", never to
#                         REASON-ABSENT, which is a distinct claim: "the hook fired but
#                         delivered no reason" vs "we could not check").
#
# Best-effort: always exits 0 (an informational renderer must not fail the probe job);
# a missing marker-path argument breadcrumbs to stderr and renders nothing.

set -uo pipefail

MARKER="${1:-}"
EXECUTION_FILE="${2:-}"

if [ -z "$MARKER" ]; then
  echo "devflow: describe-pretooluse-probe.sh: no marker path argument — rendering nothing" >&2
  exit 0
fi

_DPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-jq.sh
. "$_DPP_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: describe-pretooluse-probe.sh: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
if [ -z "${DEVFLOW_JQ:-}" ]; then
  DEVFLOW_JQ=jq
fi

echo "## PreToolUse shape-guard settings-input probe (issue #908 AC7)"

if [ -f "$MARKER" ]; then
  echo "- observed: **FIRED** — the \`settings\` input registered a PreToolUse hook matching \`Bash\`, and it executed under claude-code-action (breadcrumb \`$MARKER\` present)."
else
  echo "- observed: **NOT-FIRED** — breadcrumb \`$MARKER\` absent (an established negative: the probe checked and found no evidence the hook ran)."
fi

# Reason-delivery axis: does a permissionDecisionReason the ad hoc probe hook emits
# reach the execution transcript? This is distinct from marker presence — the marker
# proves the hook's own shell command ran; the reason axis proves claude-code-action
# actually surfaces hookSpecificOutput.permissionDecisionReason text to the transcript
# it writes out. Detected via a jq slurp-and-recurse pass (mirrors
# surface-execution-diagnostics.sh's tolerance for array / object / JSONL encodings —
# `-s` slurps one-or-many top-level JSON values, `..` then reaches any nesting depth)
# rather than a raw-text grep, because the execution file's on-disk shape is not a
# pinned public contract.
if [ -z "$EXECUTION_FILE" ] || [ ! -f "$EXECUTION_FILE" ] || [ ! -s "$EXECUTION_FILE" ]; then
  echo "- reason delivery: **unavailable** (execution file absent, empty, or not supplied — could not check)"
  exit 0
fi

if ! "$DEVFLOW_JQ" --version >/dev/null 2>&1; then
  echo "- reason delivery: **unavailable** (jq ('$DEVFLOW_JQ') is not runnable — set DEVFLOW_JQ to override)"
  exit 0
fi

# `contains`, not `startswith` (issue #908 review): the execution file's on-disk shape
# is not a pinned public contract (see the header note above), so the harness may
# surface `permissionDecisionReason` wrapped inside a larger transcript string (e.g. a
# "PreToolUse:Bash [hook] devflow pretooluse-probe: ..." envelope). `startswith` would
# report a confident false REASON-ABSENT on exactly that shape — the one axis this
# probe exists to measure. The marker prefix is already distinctive, so `contains` is
# strictly more robust with no added false-positive risk.
FOUND=$("$DEVFLOW_JQ" -rs '
  [ .. | strings | select(contains("devflow pretooluse-probe:")) ] | length > 0
' "$EXECUTION_FILE" 2>/dev/null) || FOUND=""

case "$FOUND" in
  true)
    echo "- reason delivery: **REASON-DELIVERED** — a \`permissionDecisionReason\` string carrying the probe's marker prefix (\`devflow pretooluse-probe:\`) was found in the execution transcript."
    ;;
  false)
    echo "- reason delivery: **REASON-ABSENT** — the execution transcript parsed cleanly but carries no \`permissionDecisionReason\` string with the probe's marker prefix."
    ;;
  *)
    echo "- reason delivery: **unavailable** (execution file present but could not be parsed as JSON/JSONL)"
    ;;
esac

exit 0
