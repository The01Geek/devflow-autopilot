#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# actionable-patterns.sh — emit the list of patterns that currently warrant
# being filed as a retrospective issue, honouring min_occurrences and
# cooldown_days config.
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
#       "slug":             <string>,          # URL-safe issue-filing slug (== tag)
#       "occurrence_count": <int>,
#       "status":           "open"|"regressed",
#       "first_seen":       <iso8601|null>,
#       "last_seen":        <iso8601|null>,
#       "occurrences":      [...],
#       "descriptors":      [<string>, ...],   # union of the occurrences' free-text
#                                              #   descriptors — Stage B reads these to
#                                              #   decide if the cluster is one fix or many
#       "cooldown_active":  <bool>             # true if an open filed retrospective
#                                              #   issue for this slug was created
#                                              #   within cooldown_days
#     }
#
# Environment:
#   DEVFLOW_GH  override the gh binary (default: gh). Used by tests for stubbing.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Source config helpers.
# shellcheck source=lib/config-source.sh
. "$HERE/config-source.sh"

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

# ── Fetch open filed retrospective issues and build slug→createdAt map ───────
# Each pattern the loop files becomes an open issue titled
# "[devflow-retrospective] meta: <slug> — <title>" (see lib/meta-issue.sh). A
# pattern with such an issue still open and created within cooldown_days is in
# cooldown — don't re-file it this run. (The permanent overrides.json dismissal
# meta-issue.sh writes is the cross-run guard; this is the within-window one,
# meaningful when a maintainer has cleared the dismissal to allow re-filing.)
# Split the fetch from the jq so a gh failure (auth/rate-limit/network) and a
# non-JSON body each get a SPECIFIC breadcrumb naming the cause — the same
# fail-loud discipline meta-issue.sh's de-dupe lookup uses — instead of an opaque
# set -e/pipefail abort that points at neither the cooldown step nor its cause.
_OPEN_ISSUES_RAW="$("$DEVFLOW_GH" issue list --search "[devflow-retrospective] meta: in:title" \
    --state open --json number,title,createdAt --limit 200)" \
  || { echo "::error::actionable-patterns: open-issue cooldown lookup failed (gh issue list)" >&2; exit 1; }
OPEN_ISSUE_MAP="$(
  printf '%s' "$_OPEN_ISSUES_RAW" \
  | jq '
      [ .[]
        # Parse the slug token from the de-dup title prefix; drop any issue whose
        # title does not carry it (foreign issue that matched the search loosely).
        | (.title | capture("\\[devflow-retrospective\\] meta: (?<slug>[A-Za-z0-9_-]+)") | .slug) as $slug
        | select($slug != null and $slug != "")
        | { slug: $slug, createdAt: .createdAt }
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
)" || { echo "::error::actionable-patterns: could not parse the open-issue list as JSON (gh returned non-JSON?): $(printf '%s' "$_OPEN_ISSUES_RAW" | head -c 200)" >&2; exit 1; }

# Defense-in-depth: the map above silently drops any open issue whose title
# carries the de-dup prefix but whose slug token does not match the capture. A
# slug-grammar drift between meta-issue.sh's title format and this capture would
# make every drifted issue invisible to the cooldown and re-file duplicates with
# no breadcrumb — so count the drops and surface them (the round-trip test pins
# the canonical case; this catches a future drift in the field).
_DROPPED_COUNT="$(
  printf '%s' "$_OPEN_ISSUES_RAW" \
  | jq '[ .[]
          | select((.title | test("\\[devflow-retrospective\\] meta: "))
                   and ((.title | test("\\[devflow-retrospective\\] meta: [A-Za-z0-9_-]+")) | not)) ]
        | length' 2>/dev/null || echo 0
)"
if [ "${_DROPPED_COUNT:-0}" -gt 0 ]; then
    echo "::warning::actionable-patterns: ${_DROPPED_COUNT} open '[devflow-retrospective] meta:' issue(s) had an unparseable slug and were skipped for cooldown — possible slug-grammar drift vs meta-issue.sh" >&2
fi

# ── Cooldown boundary (epoch seconds for COOLDOWN days ago) ─────────────────
# Portable date math via python3 (GNU `date -d` is unavailable on macOS/BSD).
COOLDOWN_EPOCH="$(python3 -c "import datetime as d; print(int((d.datetime.now(d.timezone.utc)-d.timedelta(days=${COOLDOWN})).timestamp()))")"

# ── Build output array ───────────────────────────────────────────────────────
# For each tag in the pattern view where status is "open" or "regressed"
# and occurrence_count >= MIN, emit an entry with cooldown_active resolved.

OUTPUT="$(
  jq -n --argjson pattern_view    "$PATTERN_VIEW" \
        --argjson open_issue_map  "$OPEN_ISSUE_MAP" \
        --argjson min             "$MIN" \
        --argjson cooldown_epoch  "$COOLDOWN_EPOCH" '
    [
      $pattern_view
      | to_entries[]
      | select(.value.status == "open" or .value.status == "regressed")
      | select(.value.occurrence_count >= $min)
      | .key as $tag
      | .value as $v
      # keys from compute-patterns.jq are already canonical slugs
      | $tag as $slug
      | ($open_issue_map | has($slug)) as $has_issue
      | (
          if $has_issue then
            (($open_issue_map[$slug]
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
