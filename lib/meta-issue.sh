#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# meta-issue.sh — the retrospective loop's issue filer: file (or update) one
# GitHub issue for a devflow pattern and record a cooldown dismissal in
# overrides.json. The body is authored by Stage B (retrospective-audit) to
# create-issue quality and is filed verbatim, so the issue can later be executed
# through the normal /devflow:implement -> review pipeline.
#
# Usage:
#   meta-issue.sh --tag <theme-tag> --slug <sanitized-tag> \
#                 --title <issue-title> --body-file <path> \
#                 --overrides <path> [--dry-run]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# The reserved DevFlow provenance label plus a fixed Retrospective marker stamped
# on every filed issue. Both are hardcoded constants — no config key controls
# them (DevFlow is the scan/classify provenance string; Retrospective marks the
# loop's own filings). Application is best-effort and never aborts the filing.
_apply_labels() {  # $1 = issue number
    local _num="$1" _lbl
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    [[ -n "$_num" ]] || return 0
    for _lbl in DevFlow Retrospective; do
        DEVFLOW_GH="$DEVFLOW_GH" "$HERE/../scripts/ensure-label.sh" "$_lbl" || true
    done
    "$DEVFLOW_GH" issue edit "$_num" --add-label DevFlow --add-label Retrospective \
        >/dev/null 2>&1 \
      || echo "::warning::meta-issue: could not apply DevFlow/Retrospective labels to #${_num} (best-effort, continuing)" >&2
}

# ── Step 1: de-dupe — find or create the issue ──────────────────────────────
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
            --body "Pattern \`${TAG}\` recurred again — see the latest retrospective-weekly run." \
            >/dev/null \
          || echo "::warning::meta-issue: failed to add recurrence comment to #${NUMBER}" >&2
    fi
    _apply_labels "$NUMBER"
    echo "meta-issue: updated ${URL}" >&2
else
    if [[ "$DRY_RUN" -eq 1 ]]; then
        URL="https://example.invalid/issues/DRYRUN"
    else
        # The "[devflow-retrospective] meta: ${TAG}" prefix is the de-dupe key the
        # Step-1 search matches on (keep it verbatim); the caller's --title is
        # appended so the issue carries a human-readable summary too. The body
        # is the Stage-B-authored issue spec, filed verbatim.
        # COUPLED SITE: lib/actionable-patterns.sh re-parses the slug back out of
        # this exact title (its cooldown map captures the token after "meta: ") —
        # change this format and update that regex in lockstep (a run.sh
        # round-trip assertion pins the two together).
        URL="$("$DEVFLOW_GH" issue create \
            --title "[devflow-retrospective] meta: ${TAG} — ${TITLE}" \
            --body-file "$BODY_FILE")"
        URL="$(printf '%s' "$URL" | tr -d '[:space:]')"
    fi
    # Derive the issue number from the created URL (trailing path segment) so the
    # labels land on the issue we just filed.
    _apply_labels "${URL##*/}"
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
        dismissed_by: "retrospective-weekly",
        reason: "meta-plugin-issue",
        meta_issue: $url
    }' \
    "$OVERRIDES" > "$OVERRIDES_TMP" \
  || { rm -f "$OVERRIDES_TMP"; echo "::error::meta-issue: failed to update ${OVERRIDES}" >&2; exit 1; }
mv "$OVERRIDES_TMP" "$OVERRIDES"

# ── Step 3: print URL to stdout ───────────────────────────────────────────────
printf '%s\n' "$URL"
