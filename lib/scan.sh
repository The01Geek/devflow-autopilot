#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# scan.sh — emit JSON array of unprocessed PRs matching the retrospection predicate.
#
# A PR qualifies when ANY of: it carries the reserved DevFlow label
# (author/branch-agnostic), it is by a watched author and closes >=1 issue, or
# implementation_branch_prefix is set non-empty and its branch matches it. See
# the RETRO_PREDICATE block below.
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

# jq binary: resolved once via the shared execution-verified resolver
# (lib/resolve-bin.sh, issue #247); an explicit DEVFLOW_JQ still wins, so test
# stubs and the Windows escape hatch are honored.
# Best-effort: when the resolver is not beside this script (a copied/vendored
# deployment), fall back to bare `jq` with a breadcrumb rather than aborting
# under the caller's set -e.
_DEVFLOW_RESOLVE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-bin.sh"
if [ -f "$_DEVFLOW_RESOLVE_BIN" ]; then
  # shellcheck source=resolve-bin.sh
  . "$_DEVFLOW_RESOLVE_BIN"
  : "${DEVFLOW_JQ:=$(devflow_resolve_bin jq)}"
else
  echo "devflow: lib/resolve-bin.sh not found beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2
  : "${DEVFLOW_JQ:=jq}"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins, so test stubs are untouched.
# shellcheck source=resolve-gh.sh
. "$HERE/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"
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
# Adopter's implementation-bot branch prefix (default "claude/"). An EMPTY
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
#   (c) implementation_branch_prefix is set non-empty AND its branch matches it
# Inputs: $impl (prefix string, "" disables path c), $watched (bool).
# Operates on one PR object carrying .labels, .closingIssuesReferences,
# .headRefName (each defaulted, so a missing field never aborts the filter).
# .labels entries may be objects ({name}) or bare strings depending on the gh
# call/stub, so normalise to the name before comparing.
RETRO_PREDICATE='
  ((.labels // []) | map(if type == "object" then (.name // "") else . end) | any(. == "DevFlow"))
  or ($watched and (((.closingIssuesReferences // []) | length) > 0))
  or (($impl != "") and ((.headRefName // "") | startswith($impl)))
'

# ── _add_candidates <json-array> ─────────────────────────────────────────────
# Fold a batch of PR objects into the running CANDIDATES set, deduplicating by
# number. Shared by every mode so the union/dedupe rule lives in one place.
_add_candidates() {  # $1 = JSON array of PR objects
    CANDIDATES="$("$DEVFLOW_JQ" -nc --argjson a "$CANDIDATES" --argjson b "$1" '$a + $b | unique_by(.number)')"
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
    # Scratch for the predicate jq's stderr, so a detonation breadcrumb names the
    # actual jq diagnostic (e.g. "Cannot iterate over string") and not just an
    # exit code. Overwritten per PR, read immediately, removed before the print.
    # Trap-cleaned so a mid-loop `set -e` abort can't orphan it in $TMPDIR.
    PRS_ERR="$(mktemp)"
    trap 'rm -f "$PRS_ERR"' EXIT
    IFS=',' read -ra _prs <<< "$EXPLICIT_PRS"
    for _p in "${_prs[@]}"; do
        _p="$(echo "$_p" | xargs)"
        [ -n "$_p" ] || continue
        if ! _PRJSON="$("$DEVFLOW_GH" pr view "$_p" --repo "$REPO" --json number,headRefName,mergedAt,state,labels,closingIssuesReferences,author 2>/dev/null)"; then
            echo "::warning::scan --prs: could not fetch PR ${_p}; skipping" >&2; continue
        fi
        _STATE="$(echo "$_PRJSON" | "$DEVFLOW_JQ" -r '.state // ""')"
        _HEAD="$(echo "$_PRJSON" | "$DEVFLOW_JQ" -r '.headRefName // ""')"
        if [ "$_STATE" != "MERGED" ]; then
            echo "::warning::scan --prs: PR ${_p} is ${_STATE:-unknown}, not MERGED; skipping" >&2; continue
        fi
        _WATCHED=false
        _author_is_watched "$(echo "$_PRJSON" | "$DEVFLOW_JQ" -r '.author.login // ""')" && _WATCHED=true
        # Split the jq exit status from the empty-result case. `select(…)` emits the
        # object on a match and nothing on a legitimate non-match — both exit 0 — so
        # the empty string alone cannot distinguish "evaluated and excluded" from
        # "the predicate never ran". A non-zero jq exit means the filter detonated
        # (e.g. a non-array `labels` slips the predicate's `// []` guard, so `map`
        # aborts); report that as a distinct "predicate evaluation failed"
        # breadcrumb rather than the misleading "matches no retrospection path".
        # Non-fatal by design here (warn + `continue`), unlike weekly mode's
        # degraded gate: --prs is the operator-named ad-hoc path, so a per-PR
        # breadcrumb on stderr is the right granularity rather than a hard exit.
        set +e
        _SEL="$(echo "$_PRJSON" | "$DEVFLOW_JQ" -c --arg impl "$IMPL_PREFIX" --argjson watched "$_WATCHED" \
            "select($RETRO_PREDICATE) | {number, headRefName, mergedAt}" 2>"$PRS_ERR")"
        _SEL_RC=$?
        set -e
        if [ "$_SEL_RC" -ne 0 ]; then
            echo "::warning::scan --prs: PR ${_p} (branch '${_HEAD}') predicate evaluation failed (jq exit ${_SEL_RC}: $(tr '\n' ' ' < "$PRS_ERR" | cut -c1-300)); skipping" >&2; continue
        fi
        if [ -z "$_SEL" ]; then
            echo "::warning::scan --prs: PR ${_p} (branch '${_HEAD}') matches no retrospection path; skipping" >&2; continue
        fi
        _add_candidates "[$_SEL]"
    done
    rm -f "$PRS_ERR"
    echo "$CANDIDATES" | "$DEVFLOW_JQ" -c --argjson cap "$MAX_PRS" 'sort_by(.mergedAt) | [.[0:$cap][] | {number, headRefName, mergedAt}]'
    exit 0
fi

# ── Weekly mode ──────────────────────────────────────────────────────────────
# Portable "7 days ago" (GNU `date -d` is not available on macOS/BSD; python3 is
# a hard dependency, so use it for date math).
SINCE="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=7)).strftime("%Y-%m-%d"))')"

CANDIDATES='[]'
# Set when ANY candidate-source fetch or jq-reshape below hard-fails. Each such
# failure currently logs a ::warning::, substitutes an empty batch, and the run
# proceeds — so a partial GitHub outage silently UNDER-COUNTS the unprocessed set
# and exits 0, which a scheduled cron reads as "0 new PRs to retrospect" (the
# silent no-op the retrospective exists to eliminate). The degraded gate after
# the searches turns that into a non-zero exit.
DEGRADED=0
# Captures the stderr of each candidate-source fetch/reshape so the breadcrumbs
# below — and the now-FATAL degraded gate — can name the actual gh/jq cause (auth
# expiry vs rate-limit vs a malformed shape) rather than a generic "failed". One
# scratch file, overwritten per call (each breadcrumb reads it immediately, before
# the next call), removed just before the gate; collapse newlines and cap length
# so a breadcrumb stays a single bounded line. Trap-cleaned at creation so a
# `set -e` abort between here and the explicit `rm -f` below cannot orphan it;
# the later `RESP`/`ERR` trap replaces this one only after FETCH_ERR is removed.
FETCH_ERR="$(mktemp)"
trap 'rm -f "$FETCH_ERR"' EXIT

# ── Path (a): label pass — author- and branch-agnostic ───────────────────────
# Every merged PR carrying the reserved DevFlow provenance label in the window
# qualifies, regardless of author or branch name. This runs even when no
# watched authors are configured (the label is the branch-naming-independent
# detection mechanism). Best-effort: a gh failure logs and yields no candidates.
if LABEL_BATCH="$("$DEVFLOW_GH" pr list --repo "$REPO" --state merged --label DevFlow \
        --search "merged:>=${SINCE}" \
        --json number,headRefName,mergedAt --limit 100 2>"$FETCH_ERR")"; then
    LABEL_BATCH="$(echo "$LABEL_BATCH" | "$DEVFLOW_JQ" '[.[] | {number, headRefName, mergedAt}]' 2>"$FETCH_ERR")" \
        || { echo "::warning::scan: jq reshape of the DevFlow-label batch failed ($(tr '\n' ' ' < "$FETCH_ERR" | cut -c1-300)); treating as empty" >&2; LABEL_BATCH='[]'; DEGRADED=1; }
else
    echo "::warning::gh pr list --label DevFlow failed ($(tr '\n' ' ' < "$FETCH_ERR" | cut -c1-300))" >&2; LABEL_BATCH='[]'; DEGRADED=1
fi
_add_candidates "$LABEL_BATCH"

# ── Paths (b)–(c): watched-author search ─────────────────────────────────────
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
                    --json number,headRefName,author,mergedAt,labels,closingIssuesReferences --limit 100 2>"$FETCH_ERR")"; then
                # These are watched-author results, so $watched is true for the
                # closes-issue path (b). Filter locally with the shared predicate.
                BATCH="$(echo "$BATCH" | "$DEVFLOW_JQ" --arg impl "$IMPL_PREFIX" --argjson watched true \
                    "[.[] | select($RETRO_PREDICATE) | {number, headRefName, mergedAt}]" 2>"$FETCH_ERR")" \
                    || { echo "::warning::scan: jq reshape failed for author:${_form} ($(tr '\n' ' ' < "$FETCH_ERR" | cut -c1-300)); treating as empty" >&2; BATCH='[]'; DEGRADED=1; }
            else
                echo "::warning::gh pr list failed for author:${_form} ($(tr '\n' ' ' < "$FETCH_ERR" | cut -c1-300))" >&2; BATCH='[]'; DEGRADED=1
            fi
            _add_candidates "$BATCH"
        done
    done
fi

rm -f "$FETCH_ERR"

# ── Degraded gate ─────────────────────────────────────────────────────────────
# If any candidate-source fetch/reshape above hard-failed, the unprocessed-PR set
# is under-counted. Fail non-zero (mirroring the retrospectives.jsonl hard-read
# error below) so the partial outage is not mistaken for "0 new PRs to
# retrospect" — exit before the processed-filter read; an under-counted set must
# never reach stdout looking complete. The per-source ::warning::s above already
# named each specific gh/jq cause; this gate is the fatal summary.
if [ "$DEGRADED" -ne 0 ]; then
    echo "::error::scan: one or more candidate-source fetches failed; the unprocessed-PR set would be under-counted. Exiting non-zero rather than reporting a partial set as complete." >&2
    exit 1
fi

# ── _decode_existing <jsonl-text> <source-label> ─────────────────────────────
# Parse decoded retrospectives.jsonl text into a JSON array of processed PR
# numbers (sets the global EXISTING), failing loud (exit 1) on either silent-
# collapse mode under HTTP 200:
#   - a jq parse failure (unparseable content), or
#   - a successful parse that yields zero pr records from non-empty content
#     (pr-less / schema-drifted / truncated-but-still-parseable content).
# This assumes the file's append-only schema, where every record carries a
# {"pr":...} field: a populated file then holds >=1 such record, and an absent
# file is the 404 path above (never an empty 200), so zero records from real
# content is corruption, not an empty backlog. (If a record type WITHOUT a `.pr`
# field is ever added to the file, revisit this guard — it would fire on a
# legitimately pr-less record.) Swallowing a collapse into an empty EXISTING
# would re-queue the whole backlog and create duplicate retrospectives. BOTH call
# sites (the inline <=1 MB content and the >1 MB download_url body) share this
# guard, so neither transport can collapse silently. Called in the current shell
# (never via $(...)), so its exit terminates scan, not just a subshell.
_decode_existing() {  # $1 = decoded jsonl text, $2 = source label for breadcrumbs
    if ! EXISTING="$(printf '%s' "$1" | "$DEVFLOW_JQ" -s 'map(.pr // empty)' 2>"$ERR")"; then
        echo "::error::scan: parsing retrospectives.jsonl ($2) failed — unparseable content under HTTP 200: $(cat "$ERR")" >&2
        exit 1
    fi
    if [ "$(printf '%s' "$EXISTING" | "$DEVFLOW_JQ" 'length')" -eq 0 ]; then
        echo "::error::scan: retrospectives.jsonl ($2) yielded zero pr records from non-empty content under HTTP 200 (a decode/parse miss, or otherwise pr-less/schema-drifted content) — refusing to treat the backlog as unprocessed (would re-queue everything and create duplicate retrospectives)" >&2
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
        # Validate the Contents-API envelope parses as JSON once, up front, so an
        # unparseable 200 body fails with an accurate breadcrumb HERE rather than
        # being misattributed downstream to "neither content nor download_url"
        # (jq on a non-JSON body yields empty stdout + nonzero, which downstream
        # would otherwise read as an absent `.content` field). $ERR is single-use
        # scratch: every `2>"$ERR"` truncates it and each reader cats it right
        # after its own write, so breadcrumbs never cross streams.
        if ! RAW="$(printf '%s' "$BODY_JSON" | "$DEVFLOW_JQ" -r '.content // ""' 2>"$ERR")"; then
            echo "::error::scan: HTTP 200 for retrospectives.jsonl but the Contents API envelope was not parseable JSON: $(cat "$ERR")" >&2
            exit 1
        fi
        if [ -n "$RAW" ]; then
            # The Contents API base64-encodes `content` (with embedded newlines)
            # for files <= 1 MB. Decode via python3 (already a hard dep — see the
            # date math above; portable across macOS/BSD, unlike `base64 -d`) so a
            # decode miss gets a specific breadcrumb instead of a bare set -e
            # abort. Whitespace is stripped first (GitHub wraps the base64) and
            # validate=True rejects genuinely-invalid input rather than silently
            # discarding non-alphabet bytes the way a lenient decoder would.
            if ! DECODED="$(printf '%s' "$RAW" | python3 -c 'import sys, base64; sys.stdout.buffer.write(base64.b64decode("".join(sys.stdin.read().split()), validate=True))' 2>"$ERR")"; then
                echo "::error::scan: base64 decode of retrospectives.jsonl content failed under HTTP 200: $(cat "$ERR")" >&2
                exit 1
            fi
            _decode_existing "$DECODED" "inline content"
        else
            # The Contents API base64-encodes `content` only for files <= 1 MB;
            # for larger files it returns "" and a download_url. Fall back to it
            # so the processed-PR set doesn't silently collapse to [] (which would
            # re-queue the whole backlog and create duplicate retrospectives).
            DL_URL="$(echo "$BODY_JSON" | "$DEVFLOW_JQ" -r '.download_url // ""')"
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

UNPROC="$(echo "$CANDIDATES" | "$DEVFLOW_JQ" --argjson e "$EXISTING" '[.[] | select(.number as $n | ($e | index($n) | not))] | sort_by(.mergedAt)')"
N="$(echo "$UNPROC" | "$DEVFLOW_JQ" 'length')"
if [ "$N" -gt "$MAX_PRS" ]; then
    echo "scan: $N unprocessed PRs, capping to $MAX_PRS" >&2
fi
echo "$UNPROC" | "$DEVFLOW_JQ" -c --argjson cap "$MAX_PRS" '[.[0:$cap][] | {number, headRefName, mergedAt}]'
