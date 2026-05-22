#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# scan.sh — emit JSON array of unprocessed watched-author PRs.
#
# Usage:
#   scan.sh                       weekly mode: watched-author PRs merged in the
#                                 last 7 days, minus those already in
#                                 retrospectives.jsonl on main.
#   scan.sh --prs 774,786,772     ad-hoc mode: use exactly these PR numbers,
#                                 skipping the GitHub search AND the
#                                 already-processed filter (for backfill / a
#                                 targeted re-run / a test run). Each number is
#                                 still confirmed to be a merged retrospected
#                                 branch (claude/* or devflow/audit-*); others
#                                 are dropped with a warning.
#
# Output: [{number, headRefName, mergedAt}, ...] sorted by mergedAt, capped at
# max_prs_per_run.
set -euo pipefail

: "${DEVFLOW_GH:=gh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config-source.sh
. "$HERE/config-source.sh"

EXPLICIT_PRS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prs) EXPLICIT_PRS="$2"; shift 2 ;;
        *) echo "scan: unknown argument: $1" >&2; exit 1 ;;
    esac
done

REPO="$("$DEVFLOW_GH" repo view --json nameWithOwner -q .nameWithOwner)"
MAX_PRS="$(devflow_conf '.devflow_retrospective.max_prs_per_run' 500)"
# Adopter's implementation-bot branch prefix (default "claude/"). devflow/audit-
# is DevFlow's own internal convention and is intentionally fixed.
IMPL_PREFIX="$(devflow_conf '.devflow_retrospective.implementation_branch_prefix' 'claude/')"

# ── Retrospected-branch predicate (shared by both modes) ─────────────────────
_is_retrospected_branch() {  # $1 = headRefName
    case "$1" in ${IMPL_PREFIX}*|devflow/audit-*) return 0 ;; *) return 1 ;; esac
}

# ── Ad-hoc mode: explicit PR list, no search, no processed-filter ─────────────
if [ -n "$EXPLICIT_PRS" ]; then
    CANDIDATES='[]'
    IFS=',' read -ra _prs <<< "$EXPLICIT_PRS"
    for _p in "${_prs[@]}"; do
        _p="$(echo "$_p" | xargs)"
        [ -n "$_p" ] || continue
        if ! _PRJSON="$("$DEVFLOW_GH" pr view "$_p" --repo "$REPO" --json number,headRefName,mergedAt,state 2>/dev/null)"; then
            echo "::warning::scan --prs: could not fetch PR ${_p}; skipping" >&2; continue
        fi
        _STATE="$(echo "$_PRJSON" | jq -r '.state // ""')"
        _HEAD="$(echo "$_PRJSON" | jq -r '.headRefName // ""')"
        if [ "$_STATE" != "MERGED" ]; then
            echo "::warning::scan --prs: PR ${_p} is ${_STATE:-unknown}, not MERGED; skipping" >&2; continue
        fi
        if ! _is_retrospected_branch "$_HEAD"; then
            echo "::warning::scan --prs: PR ${_p} branch '${_HEAD}' is not a retrospected branch; skipping" >&2; continue
        fi
        CANDIDATES="$(jq -nc --argjson a "$CANDIDATES" --argjson b "$(echo "$_PRJSON" | jq '[{number, headRefName, mergedAt}]')" '$a + $b | unique_by(.number)')"
    done
    echo "$CANDIDATES" | jq -c --argjson cap "$MAX_PRS" 'sort_by(.mergedAt) | [.[0:$cap][] | {number, headRefName, mergedAt}]'
    exit 0
fi

# ── Weekly mode ──────────────────────────────────────────────────────────────
# Portable "7 days ago" (GNU `date -d` is not available on macOS/BSD; python3 is
# a hard dependency, so use it for date math).
SINCE="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=7)).strftime("%Y-%m-%d"))')"
WATCHED="$(devflow_watched_authors)"

if [ -z "$WATCHED" ]; then
    echo "::warning::no watched authors configured (devflow_retrospective.watched_authors / claude.allowed_bots)" >&2
    echo '[]'
    exit 0
fi

CANDIDATES='[]'
IFS=',' read -ra _watched <<< "$WATCHED"
for _w in "${_watched[@]}"; do
    _t="$(echo "$_w" | xargs)"; _t="${_t%\[bot\]}"
    for _form in "app/${_t}" "${_t}"; do
        if BATCH="$("$DEVFLOW_GH" pr list --repo "$REPO" --state merged \
                --search "merged:>=${SINCE} author:${_form}" \
                --json number,headRefName,author,mergedAt --limit 100 \
                --jq "[.[] | select((.headRefName|startswith(\"${IMPL_PREFIX}\")) or (.headRefName|startswith(\"devflow/audit-\")))]" 2>/dev/null)"; then
            # Also filter locally in case the --jq flag was not applied by the caller (e.g. in tests)
            BATCH="$(echo "$BATCH" | jq --arg impl "$IMPL_PREFIX" '[.[] | select((.headRefName|startswith($impl)) or (.headRefName|startswith("devflow/audit-")))]')"
        else
            echo "::warning::gh pr list failed for author:${_form}" >&2; BATCH='[]'
        fi
        CANDIDATES="$(jq -nc --argjson a "$CANDIDATES" --argjson b "$BATCH" '$a + $b | unique_by(.number)')"
    done
done

EXISTING='[]'
RESP="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$RESP" "$ERR"' EXIT
"$DEVFLOW_GH" api -i "repos/${REPO}/contents/.devflow/learnings/retrospectives.jsonl?ref=main" > "$RESP" 2>"$ERR" || true
HTTP="$(awk 'NR==1 {print $2; exit}' "$RESP")"
case "$HTTP" in
    200)
        BODY_JSON="$(awk 'BEGIN{b=0} /^\r?$/{b=1; next} b' "$RESP")"
        RAW="$(echo "$BODY_JSON" | jq -r '.content // ""')"
        if [ -n "$RAW" ]; then
            EXISTING="$(echo "$RAW" | base64 -d | jq -s 'map(.pr // empty)')"
        else
            # The Contents API base64-encodes `content` only for files <= 1 MB;
            # for larger files it returns "" and a download_url. Fall back to it
            # so the processed-PR set doesn't silently collapse to [] (which would
            # re-queue the whole backlog and create duplicate retrospectives).
            DL_URL="$(echo "$BODY_JSON" | jq -r '.download_url // ""')"
            if [ -n "$DL_URL" ]; then
                EXISTING="$("$DEVFLOW_GH" api "$DL_URL" | jq -s 'map(.pr // empty)')"
            fi
        fi
        ;;
    404)
        echo "retrospectives.jsonl not on main yet (first run)" >&2
        ;;
    *)
        echo "::error::failed reading retrospectives.jsonl from main (HTTP ${HTTP:-?}): $(cat "$ERR")" >&2
        exit 1
        ;;
esac

UNPROC="$(echo "$CANDIDATES" | jq --argjson e "$EXISTING" '[.[] | select(.number as $n | ($e | index($n) | not))] | sort_by(.mergedAt)')"
N="$(echo "$UNPROC" | jq 'length')"
if [ "$N" -gt "$MAX_PRS" ]; then
    echo "scan: $N unprocessed PRs, capping to $MAX_PRS" >&2
fi
echo "$UNPROC" | jq -c --argjson cap "$MAX_PRS" '[.[0:$cap][] | {number, headRefName, mergedAt}]'
