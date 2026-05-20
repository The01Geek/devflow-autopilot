#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# actionable-patterns.sh — emit the list of patterns that currently warrant
# an audit intervention, honouring min_occurrences and cooldown_days config.
#
# Usage:
#   bash lib/actionable-patterns.sh <retrospectives.jsonl> <overrides.json>
#
# Args:
#   $1  path to retrospectives.jsonl
#   $2  path to overrides.json
#
# Output (stdout):
#   Compact JSON array of actionable pattern objects, each shaped as:
#     {
#       "tag":              <string>,          # category slug (== slug)
#       "slug":             <string>,          # URL/branch-safe; the audit branch slug
#       "occurrence_count": <int>,
#       "status":           "open"|"regressed",
#       "first_seen":       <iso8601|null>,
#       "last_seen":        <iso8601|null>,
#       "occurrences":      [...],
#       "descriptors":      [<string>, ...],   # union of the occurrences' free-text
#                                              #   descriptors — Stage B reads these to
#                                              #   decide if the cluster is one fix or many
#       "cooldown_active":  <bool>             # true if an open audit PR for this slug
#                                              #   was created within cooldown_days
#     }
#
# Environment:
#   DEVFLOW_GH  override the gh binary (default: gh). Used by tests for stubbing.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Source config helpers.
# shellcheck source=lib/conf.sh
. "$HERE/conf.sh"

RETRO_FILE="$1"
OVERRIDES_FILE="$2"

MIN="$(devflow_conf '.devflow_retrospective.min_occurrences' 2)"
COOLDOWN="$(devflow_conf '.devflow_retrospective.cooldown_days' 3)"

: "${DEVFLOW_GH:=gh}"

# ── Stub overrides.json if absent or empty (first-run safety) ─────────────────
_OVERRIDES_ACTUAL="$OVERRIDES_FILE"
_OVERRIDES_TMP=""
if [ ! -f "$OVERRIDES_FILE" ] || [ ! -s "$OVERRIDES_FILE" ]; then
    _OVERRIDES_TMP="$(mktemp)"
    trap 'rm -f "$_OVERRIDES_TMP"' EXIT
    printf '{"schema_version":1,"dismissed":{}}' > "$_OVERRIDES_TMP"
    _OVERRIDES_ACTUAL="$_OVERRIDES_TMP"
fi

# ── Compute pattern view ─────────────────────────────────────────────────────
# If the retrospectives file doesn't exist yet (first run or empty scan),
# pipe an empty stream to jq rather than letting it error on a missing file.
if [ -f "$RETRO_FILE" ] && [ -s "$RETRO_FILE" ]; then
  PATTERN_VIEW="$(
    jq -s --slurpfile overrides "$_OVERRIDES_ACTUAL" \
       -f "$HERE/compute-patterns.jq" \
       "$RETRO_FILE"
  )"
else
  PATTERN_VIEW="$(
    printf '' | jq -s --slurpfile overrides "$_OVERRIDES_ACTUAL" \
       -f "$HERE/compute-patterns.jq"
  )"
fi

# ── Fetch open audit PRs and build slug→createdAt map ───────────────────────
OPEN_AUDIT_PR_MAP="$(
  "$DEVFLOW_GH" pr list --state open --json number,headRefName,createdAt --limit 200 \
  | jq '
      [ .[]
        | select(.headRefName | startswith("devflow/audit-"))
        | {
            slug: (
              .headRefName
              | ltrimstr("devflow/audit-")
              | gsub("^(?<p>.*)-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]+$"; "\(.p)")
            ),
            createdAt: .createdAt
          }
      ]
      | reduce .[] as $item (
          {};
          # keep newest createdAt per slug
          if has($item.slug) and .[$item.slug] >= $item.createdAt
          then .
          else . + {($item.slug): $item.createdAt}
          end
        )
    '
)"

# ── Cooldown boundary (epoch seconds for COOLDOWN days ago) ─────────────────
# Portable date math via python3 (GNU `date -d` is unavailable on macOS/BSD).
COOLDOWN_EPOCH="$(python3 -c "import datetime as d; print(int((d.datetime.now(d.timezone.utc)-d.timedelta(days=${COOLDOWN})).timestamp()))")"

# ── Build output array ───────────────────────────────────────────────────────
# For each tag in the pattern view where status is "open" or "regressed"
# and occurrence_count >= MIN, emit an entry with cooldown_active resolved.

OUTPUT="$(
  jq -n --argjson pattern_view   "$PATTERN_VIEW" \
        --argjson open_pr_map    "$OPEN_AUDIT_PR_MAP" \
        --argjson min            "$MIN" \
        --argjson cooldown_epoch "$COOLDOWN_EPOCH" '
    [
      $pattern_view
      | to_entries[]
      | select(.value.status == "open" or .value.status == "regressed")
      | select(.value.occurrence_count >= $min)
      | .key as $tag
      | .value as $v
      # keys from compute-patterns.jq are already canonical slugs
      | $tag as $slug
      | ($open_pr_map | has($slug)) as $has_pr
      | (
          if $has_pr then
            (($open_pr_map[$slug]
              | strptime("%Y-%m-%dT%H:%M:%SZ")
              | mktime) >= $cooldown_epoch)
          else false
          end
        ) as $cooldown_active
      | {
          tag: $tag,
          slug: $slug,
          occurrence_count: $v.occurrence_count,
          status: $v.status,
          first_seen: $v.first_seen,
          last_seen: $v.last_seen,
          occurrences: $v.occurrences,
          descriptors: ($v.descriptors // []),
          cooldown_active: $cooldown_active
        }
    ]
  '
)"

printf '%s\n' "$OUTPUT"
