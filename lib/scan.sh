#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# scan.sh — emit JSON array of unprocessed PRs matching the retrospection predicate.
#
# A PR qualifies when ANY of: it carries the reserved DevFlow label
# (author/branch-agnostic), it is by a watched author and closes >=1 issue, its
# branch is devflow/audit-*, or implementation_branch_prefix is set non-empty and
# its branch matches it. See the RETRO_PREDICATE block below.
#
# Usage:
#   scan.sh                       weekly mode: PRs matching the predicate merged
#                                 in the last 7 days, minus those already in
#                                 retrospectives.jsonl on main. The DevFlow-label
#                                 pass runs even with no watched authors configured.
#   scan.sh --prs 774,786,772     ad-hoc mode: use exactly these PR numbers,
#                                 skipping the GitHub search AND the
#                                 already-processed filter (for backfill / a
#                                 targeted re-run / a test run). Each number is
#                                 still confirmed to match the retrospection
#                                 predicate; others are dropped with a warning.
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
# is DevFlow's own internal convention and is intentionally fixed. An EMPTY
# prefix is honoured as "disable the prefix path" — it must NOT degrade to a
# `*`-glob that matches every branch (the old `${IMPL_PREFIX}*` bug).
IMPL_PREFIX="$(devflow_conf '.devflow_retrospective.implementation_branch_prefix' 'claude/')"
# Watched authors (comma list, [bot] suffix optional). Used by the closes-issue
# path (b); the label path (a) is deliberately author-agnostic, so it does not
# depend on this being set.
WATCHED="$(devflow_watched_authors)"

# ── Retrospection predicate (shared by every mode) ───────────────────────────
# A merged PR qualifies for retrospection when ANY of these holds:
#   (a) it carries the reserved DevFlow provenance label   (author/branch-agnostic)
#   (b) $watched is true AND it closes >=1 issue (closingIssuesReferences non-empty)
#   (c) its branch is a devflow/audit-* intervention branch
#   (d) implementation_branch_prefix is set non-empty AND its branch matches it
# Inputs: $impl (prefix string, "" disables path d), $watched (bool).
# Operates on one PR object carrying .labels, .closingIssuesReferences,
# .headRefName (each defaulted, so a missing field never aborts the filter).
# .labels entries may be objects ({name}) or bare strings depending on the gh
# call/stub, so normalise to the name before comparing.
RETRO_PREDICATE='
  ((.labels // []) | map(if type == "object" then (.name // "") else . end) | any(. == "DevFlow"))
  or ($watched and (((.closingIssuesReferences // []) | length) > 0))
  or (((.headRefName // "") | startswith("devflow/audit-")))
  or (($impl != "") and ((.headRefName // "") | startswith($impl)))
'

# ── _add_candidates <json-array> ─────────────────────────────────────────────
# Fold a batch of PR objects into the running CANDIDATES set, deduplicating by
# number. Shared by every mode so the union/dedupe rule lives in one place.
_add_candidates() {  # $1 = JSON array of PR objects
    CANDIDATES="$(jq -nc --argjson a "$CANDIDATES" --argjson b "$1" '$a + $b | unique_by(.number)')"
}

# ── _author_is_watched <login> ───────────────────────────────────────────────
# True when <login> (with an optional trailing [bot]) is in the WATCHED list.
_author_is_watched() {
    local _cand="${1%\[bot\]}" _x
    IFS=',' read -ra _wl <<< "$WATCHED"
    for _x in "${_wl[@]}"; do
        _x="$(echo "$_x" | xargs)"; _x="${_x%\[bot\]}"
        [ -n "$_x" ] && [ "$_x" = "$_cand" ] && return 0
    done
    return 1
}

# ── Ad-hoc mode: explicit PR list, no search, no processed-filter ─────────────
if [ -n "$EXPLICIT_PRS" ]; then
    CANDIDATES='[]'
    IFS=',' read -ra _prs <<< "$EXPLICIT_PRS"
    for _p in "${_prs[@]}"; do
        _p="$(echo "$_p" | xargs)"
        [ -n "$_p" ] || continue
        if ! _PRJSON="$("$DEVFLOW_GH" pr view "$_p" --repo "$REPO" --json number,headRefName,mergedAt,state,labels,closingIssuesReferences,author 2>/dev/null)"; then
            echo "::warning::scan --prs: could not fetch PR ${_p}; skipping" >&2; continue
        fi
        _STATE="$(echo "$_PRJSON" | jq -r '.state // ""')"
        _HEAD="$(echo "$_PRJSON" | jq -r '.headRefName // ""')"
        if [ "$_STATE" != "MERGED" ]; then
            echo "::warning::scan --prs: PR ${_p} is ${_STATE:-unknown}, not MERGED; skipping" >&2; continue
        fi
        _WATCHED=false
        _author_is_watched "$(echo "$_PRJSON" | jq -r '.author.login // ""')" && _WATCHED=true
        _SEL="$(echo "$_PRJSON" | jq -c --arg impl "$IMPL_PREFIX" --argjson watched "$_WATCHED" \
            "select($RETRO_PREDICATE) | {number, headRefName, mergedAt}" 2>/dev/null || true)"
        if [ -z "$_SEL" ]; then
            echo "::warning::scan --prs: PR ${_p} (branch '${_HEAD}') matches no retrospection path; skipping" >&2; continue
        fi
        _add_candidates "[$_SEL]"
    done
    echo "$CANDIDATES" | jq -c --argjson cap "$MAX_PRS" 'sort_by(.mergedAt) | [.[0:$cap][] | {number, headRefName, mergedAt}]'
    exit 0
fi

# ── Weekly mode ──────────────────────────────────────────────────────────────
# Portable "7 days ago" (GNU `date -d` is not available on macOS/BSD; python3 is
# a hard dependency, so use it for date math).
SINCE="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=7)).strftime("%Y-%m-%d"))')"

CANDIDATES='[]'

# ── Path (a): label pass — author- and branch-agnostic ───────────────────────
# Every merged PR carrying the reserved DevFlow provenance label in the window
# qualifies, regardless of author or branch name. This runs even when no
# watched authors are configured (the label is the branch-naming-independent
# detection mechanism). Best-effort: a gh failure logs and yields no candidates.
if LABEL_BATCH="$("$DEVFLOW_GH" pr list --repo "$REPO" --state merged --label DevFlow \
        --search "merged:>=${SINCE}" \
        --json number,headRefName,mergedAt --limit 100 2>/dev/null)"; then
    LABEL_BATCH="$(echo "$LABEL_BATCH" | jq '[.[] | {number, headRefName, mergedAt}]' 2>/dev/null)" \
        || { echo "::warning::scan: jq reshape of the DevFlow-label batch failed; treating as empty" >&2; LABEL_BATCH='[]'; }
else
    echo "::warning::gh pr list --label DevFlow failed" >&2; LABEL_BATCH='[]'
fi
_add_candidates "$LABEL_BATCH"

# ── Paths (b)–(d): watched-author search ─────────────────────────────────────
# Skipped (not fatal) when no watched authors are configured — the label pass
# above still stands on its own.
if [ -z "$WATCHED" ]; then
    echo "::warning::no watched authors configured (devflow_retrospective.watched_authors / devflow.allowed_bots); relying on the DevFlow-label path only" >&2
else
    IFS=',' read -ra _watched <<< "$WATCHED"
    for _w in "${_watched[@]}"; do
        _t="$(echo "$_w" | xargs)"; _t="${_t%\[bot\]}"
        for _form in "app/${_t}" "${_t}"; do
            if BATCH="$("$DEVFLOW_GH" pr list --repo "$REPO" --state merged \
                    --search "merged:>=${SINCE} author:${_form}" \
                    --json number,headRefName,author,mergedAt,labels,closingIssuesReferences --limit 100 2>/dev/null)"; then
                # These are watched-author results, so $watched is true for the
                # closes-issue path (b). Filter locally with the shared predicate.
                BATCH="$(echo "$BATCH" | jq --arg impl "$IMPL_PREFIX" --argjson watched true \
                    "[.[] | select($RETRO_PREDICATE) | {number, headRefName, mergedAt}]" 2>/dev/null)" \
                    || { echo "::warning::scan: jq reshape failed for author:${_form}; treating as empty" >&2; BATCH='[]'; }
            else
                echo "::warning::gh pr list failed for author:${_form}" >&2; BATCH='[]'
            fi
            _add_candidates "$BATCH"
        done
    done
fi

# ── _decode_existing <jsonl-text> <source-label> ─────────────────────────────
# Parse decoded retrospectives.jsonl text into a JSON array of processed PR
# numbers (sets the global EXISTING). A `jq` parse failure under HTTP 200 means
# the content was unparseable (a decode miss) — fail loud (exit 1) with a
# breadcrumb naming the source path, rather than swallowing it into an empty
# EXISTING that would re-queue the whole backlog and create duplicate
# retrospectives. Called in the current shell (never via $(...)), so its exit
# terminates scan, not just a subshell.
_decode_existing() {  # $1 = decoded jsonl text, $2 = source label for breadcrumbs
    if ! EXISTING="$(printf '%s' "$1" | jq -s 'map(.pr // empty)' 2>"$ERR")"; then
        echo "::error::scan: parsing retrospectives.jsonl ($2) failed — unparseable content under HTTP 200: $(cat "$ERR")" >&2
        exit 1
    fi
}

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
            # The Contents API base64-encodes `content` (with embedded newlines)
            # for files <= 1 MB. Decode explicitly so a base64 miss gets a
            # specific breadcrumb instead of a bare set -e abort.
            if ! DECODED="$(printf '%s' "$RAW" | base64 -d 2>"$ERR")"; then
                echo "::error::scan: base64 decode of retrospectives.jsonl content failed under HTTP 200: $(cat "$ERR")" >&2
                exit 1
            fi
            _decode_existing "$DECODED" "inline content"
            # A non-empty `content` field always carries >=1 {"pr":...} record:
            # the file is created by the first append, so an absent file is the
            # 404 path above, never an empty 200. A zero-record result from
            # non-empty content is therefore a silent decode/parse collapse —
            # fail loud rather than treat the whole backlog as unprocessed (which
            # would re-queue everything and create duplicate retrospectives).
            if [ "$(printf '%s' "$EXISTING" | jq 'length')" -eq 0 ]; then
                echo "::error::scan: retrospectives.jsonl decoded to zero pr records from non-empty content under HTTP 200 — refusing to treat the backlog as unprocessed (would re-queue everything and create duplicate retrospectives)" >&2
                exit 1
            fi
        else
            # The Contents API base64-encodes `content` only for files <= 1 MB;
            # for larger files it returns "" and a download_url. Fall back to it
            # so the processed-PR set doesn't silently collapse to [] (which would
            # re-queue the whole backlog and create duplicate retrospectives).
            DL_URL="$(echo "$BODY_JSON" | jq -r '.download_url // ""')"
            if [ -z "$DL_URL" ]; then
                echo "::error::scan: HTTP 200 for retrospectives.jsonl but it carried neither inline content nor a download_url — cannot determine the processed-PR set; refusing to re-queue the whole backlog" >&2
                exit 1
            fi
            if ! DL_BODY="$("$DEVFLOW_GH" api "$DL_URL" 2>"$ERR")"; then
                echo "::error::scan: fetching retrospectives.jsonl via download_url failed: $(cat "$ERR")" >&2
                exit 1
            fi
            _decode_existing "$DL_BODY" "download_url"
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
