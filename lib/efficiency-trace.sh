#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# efficiency-trace.sh — render the /devflow:review-and-fix per-run subagent
# effectiveness trace (Markdown) or the per-run JSON record from a run's
# per-iteration workpads. All derivation lives in lib/efficiency-trace.jq;
# this wrapper validates inputs, reads the gating config, and dispatches jq.
#
# Usage:
#   bash lib/efficiency-trace.sh --workpad-dir DIR --slug SLUG --mode {trace|record}
#
# Args:
#   --workpad-dir DIR   directory holding the run's iter-<N>.json workpads
#                       (e.g. .devflow/tmp/review/<slug>/).
#   --slug SLUG         the run slug (pr-<N> or sanitized branch name).
#   --mode trace        emit the rendered Markdown trace to stdout.
#   --mode record       emit the per-run JSON record to stdout.
#
# Gating: when devflow_review_and_fix.efficiency_telemetry_enabled is false,
# this script emits NOTHING and exits 0 — so callers writing the record to a
# file produce no file under .devflow/logs/ (the flag-off contract).
#
# Best-effort: a missing dir, zero readable workpads, or an unreadable workpad
# never aborts — the trace/record degrade gracefully (empty trace, empty
# per_iteration). The caller (SKILL.md Loop Exit) must itself stay non-fatal.
#
# Environment:
#   DEVFLOW_CONFIG_FILE  override the config path (used by tests).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/config-source.sh
. "$HERE/config-source.sh"

WORKPAD_DIR=""
SLUG=""
MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --workpad-dir) WORKPAD_DIR="$2"; shift 2 ;;
    --slug)        SLUG="$2";        shift 2 ;;
    --mode)        MODE="$2";        shift 2 ;;
    *) echo "efficiency-trace.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ "$MODE" != "trace" ] && [ "$MODE" != "record" ]; then
  echo "efficiency-trace.sh: --mode must be 'trace' or 'record'" >&2
  exit 2
fi

# ── Gating flag (on by default). Flag off → emit nothing, exit 0. ────────────
ENABLED="$(devflow_conf '.devflow_review_and_fix.efficiency_telemetry_enabled' 'true')"
if [ "$ENABLED" != "true" ]; then
  exit 0
fi

THRESHOLD="$(devflow_conf '.devflow_review_and_fix.efficiency_cut_candidate_min_dispatch' 3)"
# Guard: a non-numeric / empty operator-supplied value must not make --argjson
# abort jq (and the script under set -e) — fall back to the documented default.
# Also clamp values below the schema's `minimum: 1` (e.g. 0) to the default, so
# the persisted record never carries a value config.schema.json forbids.
case "$THRESHOLD" in
  ''|*[!0-9]*) THRESHOLD=3 ;;
esac
[ "$THRESHOLD" -lt 1 ] && THRESHOLD=3
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Collect valid iter-*.json workpads (skip unreadable / malformed) ─────────
VALID_FILES=()
if [ -n "$WORKPAD_DIR" ] && [ -d "$WORKPAD_DIR" ]; then
  for f in "$WORKPAD_DIR"/iter-*.json; do
    [ -e "$f" ] || continue                       # no glob match → skip
    # Require a JSON OBJECT, not merely well-formed JSON: the filter indexes the
    # workpad as an object (.phase3_findings etc.), so a valid-but-non-object
    # file (stray array/number/string from a partial write) would crash jq and
    # abort the wrapper under set -e. Skip it instead, honoring best-effort.
    if jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      VALID_FILES+=("$f")
    else
      echo "::warning::efficiency-trace.sh: skipping unreadable/malformed workpad '$f'" >&2
    fi
  done
fi

# Future-proofing guard: a run is expected to be single-source — either a
# /devflow:review pass or a review-and-fix loop, never both. The jq collapses the
# run-level `source` to the first non-null (per-iter verdicts still key off each
# iter's own source), so a mixed-source run would silently mislabel the record.
# That input is not currently produced; warn (don't fail) if it ever appears.
# An ABSENT per-iter source counts as the run-level default ("review-and-fix",
# matching the jq's `// "review-and-fix"`), so a `review` iter mixed with a
# source-less one is correctly flagged as mixed — a bare `.source // empty` would
# drop the absent iter from the set and stay silent on that real mix.
if [ "${#VALID_FILES[@]}" -gt 1 ]; then
  # No `2>/dev/null` here: VALID_FILES already passed the `type == "object"` gate
  # above, so this jq cannot fail on malformed input — suppressing its stderr would
  # only hide a genuine jq malfunction (the project's no-silent-failure stance).
  if [ "$(jq -r '.source // "review-and-fix"' "${VALID_FILES[@]}" | sort -u | wc -l)" -gt 1 ]; then
    echo "::warning::efficiency-trace.sh: workpads carry mixed 'source' values; record collapses to the first non-null (a run should be single-source)" >&2
  fi
fi

# jq -s over zero files yields null, not []; feed an explicit empty array so the
# filter (which expects an array) degrades to an empty trace / empty record.
if [ "${#VALID_FILES[@]}" -eq 0 ]; then
  printf '[]\n' | jq --raw-output -f "$HERE/efficiency-trace.jq" \
    --arg mode "$MODE" --arg slug "$SLUG" \
    --arg generated_at "$GENERATED_AT" \
    --argjson cut_candidate_min_dispatch "$THRESHOLD"
else
  jq --raw-output --slurp -f "$HERE/efficiency-trace.jq" \
    --arg mode "$MODE" --arg slug "$SLUG" \
    --arg generated_at "$GENERATED_AT" \
    --argjson cut_candidate_min_dispatch "$THRESHOLD" \
    "${VALID_FILES[@]}"
fi
