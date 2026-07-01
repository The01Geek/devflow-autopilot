#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# post-status.sh — post or patch the audit-report comment on the state PR.
#
# Usage:
#   post-status.sh --pr <state-pr-number> --report-file <path> [--dry-run]
set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
PR=
REPORT_FILE=
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)          PR="$2";          shift 2 ;;
        --report-file) REPORT_FILE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1;        shift   ;;
        *) echo "post-status: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PR" ]; then
    echo "post-status: missing required argument --pr" >&2; exit 1
fi
if [ -z "$REPORT_FILE" ]; then
    echo "post-status: missing required argument --report-file" >&2; exit 1
fi

# ── gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins (injection for tests) ─────────────────────
# shellcheck source=resolve-gh.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

# ── Dry-run path ──────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRYRUN: would post/patch comment on PR %s\n' "$PR"
    printf '%s\n' "$REPORT_FILE"
    echo "DRYRUN"
    exit 0
fi

# ── Resolve repo ──────────────────────────────────────────────────────────────
REPO="$("$DEVFLOW_GH" repo view --json nameWithOwner -q .nameWithOwner)" \
  || { echo "::error::post-status: failed to resolve repo name" >&2; exit 1; }

# ── Check for existing comment with the marker ───────────────────────────────
CID="$("$DEVFLOW_GH" api \
    "repos/${REPO}/issues/${PR}/comments" \
    --paginate \
    --jq '[.[] | select(.body | contains("<!-- devflow:audit-report -->"))] | .[0].id // empty')" \
  || { echo "::error::post-status: de-dupe comment lookup failed for PR ${PR}" >&2; exit 1; }

# ── Post or patch ─────────────────────────────────────────────────────────────
if [ -n "$CID" ]; then
    "$DEVFLOW_GH" api -X PATCH \
        "repos/${REPO}/issues/comments/${CID}" \
        -F "body=@${REPORT_FILE}"
    echo "post-status: patched existing comment ${CID} on PR ${PR}" >&2
else
    "$DEVFLOW_GH" api \
        "repos/${REPO}/issues/${PR}/comments" \
        -F "body=@${REPORT_FILE}"
    echo "post-status: posted new comment on PR ${PR}" >&2
fi
