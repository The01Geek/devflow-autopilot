#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# meta-issue.sh — file/update a GitHub meta-issue for a devflow pattern that
# touches an exclusion-list path, and record a dismissal in overrides.json.
#
# Usage:
#   meta-issue.sh --tag <theme-tag> --slug <sanitized-tag> \
#                 --title <pr-title> --body-file <path> \
#                 --overrides <path> [--dry-run]
set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────
TAG=
SLUG=
TITLE=
BODY_FILE=
OVERRIDES=
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)        TAG="$2";       shift 2 ;;
        --slug)       SLUG="$2";      shift 2 ;;
        --title)      TITLE="$2";     shift 2 ;;
        --body-file)  BODY_FILE="$2"; shift 2 ;;
        --overrides)  OVERRIDES="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1;      shift   ;;
        *) echo "meta-issue: unknown argument: $1" >&2; exit 1 ;;
    esac
done

for var in TAG SLUG TITLE BODY_FILE OVERRIDES; do
    if [[ -z "${!var}" ]]; then
        echo "meta-issue: missing required argument --${var,,}" >&2
        exit 1
    fi
done

# ── gh binary (allow injection for tests) ────────────────────────────────────
: "${DEVFLOW_GH:=gh}"

# ── Step 1: de-dupe — find or create the meta-issue ─────────────────────────
EXISTING="$("$DEVFLOW_GH" issue list \
    --search "[devflow-retrospective] meta: ${TAG} in:title" \
    --state open \
    --json number,url \
    --jq '.[0] // empty')" \
  || { echo "::error::meta-issue: de-dupe lookup failed for tag '${TAG}'" >&2; exit 1; }

if [[ -n "$EXISTING" ]]; then
    URL="$(printf '%s' "$EXISTING" | jq -r '.url')"
    NUMBER="$(printf '%s' "$EXISTING" | jq -r '.number')"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$DEVFLOW_GH" issue comment "$NUMBER" \
            --body "Pattern \`${TAG}\` recurred again — see the latest devflow-weekly run." \
            >/dev/null \
          || echo "::warning::meta-issue: failed to add recurrence comment to #${NUMBER}" >&2
    fi
    echo "meta-issue: updated ${URL}" >&2
else
    # Compose the issue body in a temp file
    COMPOSED_BODY="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$COMPOSED_BODY'" EXIT

    {
        printf '## Pattern: `%s`\n\n' "$TAG"
        cat "$BODY_FILE"
        printf '\n\n### Why this can'\''t be an auto-opened intervention PR\n\n'
        printf 'This pattern'\''s best fix lives on an exclusion-list path '
        printf '(plugin, data file, or critical-infra config). Auto-opening a '
        printf 'PR on these paths risks unintended side-effects and needs '
        printf 'human design review before any automated change is applied.\n'
    } > "$COMPOSED_BODY"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        URL="https://example.invalid/issues/DRYRUN"
    else
        URL="$("$DEVFLOW_GH" issue create \
            --title "[devflow-retrospective] meta: ${TAG}" \
            --body-file "$COMPOSED_BODY")"
        URL="$(printf '%s' "$URL" | tr -d '[:space:]')"
    fi
    echo "meta-issue: created ${URL}" >&2
fi

# ── Step 2: update overrides.json ────────────────────────────────────────────
if [[ ! -f "$OVERRIDES" ]] || [[ ! -s "$OVERRIDES" ]]; then
    printf '{"schema_version":1,"dismissed":{}}' > "$OVERRIDES"
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OVERRIDES_TMP="$(mktemp)"
jq \
    --arg tag "$SLUG" \
    --arg now "$NOW" \
    --arg url "$URL" \
    '.dismissed[$tag] = {
        dismissed_at: $now,
        dismissed_by: "devflow-weekly",
        reason: "meta-plugin-issue",
        meta_issue: $url
    }' \
    "$OVERRIDES" > "$OVERRIDES_TMP" \
  || { rm -f "$OVERRIDES_TMP"; echo "::error::meta-issue: failed to update ${OVERRIDES}" >&2; exit 1; }
mv "$OVERRIDES_TMP" "$OVERRIDES"

# ── Step 3: print URL to stdout ───────────────────────────────────────────────
printf '%s\n' "$URL"
