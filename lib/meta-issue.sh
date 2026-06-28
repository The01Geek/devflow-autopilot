#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# meta-issue.sh — the retrospective loop's issue filer: file (or update) one
# GitHub issue for a devflow pattern and record a permanent cross-run exclusion
# in overrides.json (a `dismissed` entry that holds until a human clears it —
# distinct from the within-window open-issue cooldown in actionable-patterns.sh).
# The body is authored by Stage B (retrospective-audit) to create-issue quality
# and is filed verbatim, so the issue can later be executed through the normal
# /devflow:implement -> review pipeline.
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

# Validate TAG before it is interpolated into the de-dupe `--search` string: a TAG
# carrying a GitHub search qualifier (e.g. `in:body`, `label:foo`) or whitespace
# could mis-route the lookup and make the de-dupe silently miss, re-filing a
# duplicate. TAG is canonical (a compute-patterns.jq slug) in practice; reject
# anything that is not the slug grammar so a drift fails loud at the boundary.
case "$TAG" in
    *[!A-Za-z0-9_-]*|'')
        echo "meta-issue: invalid --tag '${TAG}' (expected [A-Za-z0-9_-]+)" >&2
        exit 1 ;;
esac

# ── gh binary (allow injection for tests) ────────────────────────────────────
: "${DEVFLOW_GH:=gh}"

# The reserved DevFlow provenance label plus a fixed Retrospective marker stamped
# on every filed issue. Both are hardcoded constants — no config key controls
# them (DevFlow is the scan/classify provenance string; Retrospective marks the
# loop's own filings). Application is best-effort and never aborts the filing.
_apply_labels() {  # $1 = issue number
    local _num="$1" _lbl _err
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    # Guard the number's shape: an empty or non-numeric token (e.g. a gh warning
    # line that leaked into the URL the caller derived ${URL##*/} from) must leave
    # a SPECIFIC breadcrumb, never a silent skip — label stamping is best-effort,
    # but a label we could not even attempt should say why.
    case "$_num" in
        ''|*[!0-9]*)
            echo "::warning::meta-issue: could not derive a numeric issue number (got: '${_num}') — DevFlow/Retrospective labels NOT applied" >&2
            return 0 ;;
    esac
    for _lbl in DevFlow Retrospective; do
        DEVFLOW_GH="$DEVFLOW_GH" "$HERE/../scripts/ensure-label.sh" "$_lbl" || true
    done
    # Capture the gh stderr into the breadcrumb (mirroring ensure-label.sh's
    # discipline) so a real failure names its cause instead of a generic warning.
    _err="$("$DEVFLOW_GH" issue edit "$_num" --add-label DevFlow --add-label Retrospective 2>&1 >/dev/null)" \
      || echo "::warning::meta-issue: could not apply one or both of the DevFlow/Retrospective labels to #${_num} (best-effort, continuing): ${_err}" >&2
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
    # Fail CLOSED on a de-dup hit that yielded no usable url/number (a gh --json
    # contract drift would make jq -r emit the literal "null"). Mirrors the
    # create-path URL guard below — without it a "null" url/number would flow into
    # the recurrence comment, the labels, and the overrides cooldown.
    case "$URL" in https://*/issues/[0-9]*) : ;; *) echo "::error::meta-issue: de-dupe hit returned no usable issue URL for tag '${TAG}' (got: '${URL}')" >&2; exit 1 ;; esac
    case "$NUMBER" in ''|*[!0-9]*) echo "::error::meta-issue: de-dupe hit returned no numeric issue number for tag '${TAG}' (got: '${NUMBER}')" >&2; exit 1 ;; esac
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
        # Fail CLOSED on a non-issue-URL: `gh issue create` can exit 0 yet emit
        # empty/garbage stdout (URL printed to stderr, an auth/upgrade warning on
        # stdout, a swallowed transient error). Without this guard an empty/garbage
        # URL would flow on as a "success" — the orchestrator would record the
        # pattern as FILED and write a permanent overrides.json cooldown for an
        # issue that does not exist (the exact "never report unfiled as filed"
        # invariant this loop must hold). Exit non-zero so the orchestrator's
        # `if ISSUE_URL=$(...meta-issue.sh...)` catches it and records a blocker.
        case "$URL" in
            https://*/issues/[0-9]*) : ;;
            *) echo "::error::meta-issue: 'gh issue create' returned no usable issue URL for tag '${TAG}' (got: '${URL}')" >&2; exit 1 ;;
        esac
    fi
    # Derive the issue number from the created URL (trailing path segment) so the
    # labels land on the issue we just filed. The URL-shape guard above guarantees
    # a numeric tail on the create path; the _apply_labels numeric guard is the
    # belt-and-suspenders for the existing-issue path's parsed number.
    _apply_labels "${URL##*/}"
    echo "meta-issue: created ${URL}" >&2
fi

# ── Step 2: update overrides.json ────────────────────────────────────────────
# Skip the real mutation on a dry run — a dry run must observe, never alter the
# cross-run state. Otherwise it would record a `dismissed` entry pointing at the
# DRYRUN sentinel and a later live run would treat the slug as already filed and
# skip the real filing.
if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ ! -f "$OVERRIDES" ]] || [[ ! -s "$OVERRIDES" ]]; then
        printf '{"schema_version":1,"dismissed":{}}' > "$OVERRIDES"
    fi

    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    OVERRIDES_TMP="$(mktemp)"
    # PRESERVE the original dismissed_at on a recurrence: this entry records WHEN
    # the pattern was first dismissed (a permanent cross-run exclusion an auditor
    # reads to see how long it has been parked). The Step-1 de-dupe re-runs this
    # write on every recurrence, so writing $now unconditionally would drift the
    # timestamp perpetually forward and mislead that audit. Only a brand-new entry
    # (no prior dismissed_at) gets $now; an existing one keeps its first stamp.
    if jq \
        --arg tag "$SLUG" \
        --arg now "$NOW" \
        --arg url "$URL" \
        '.dismissed[$tag] = {
            dismissed_at: (.dismissed[$tag].dismissed_at // $now),
            dismissed_by: "retrospective-weekly",
            reason: "meta-plugin-issue",
            meta_issue: $url
        }' \
        "$OVERRIDES" > "$OVERRIDES_TMP"; then
        mv "$OVERRIDES_TMP" "$OVERRIDES"
    else
        # The issue WAS filed (URL is on stdout below); only the cooldown record
        # failed. Do NOT report this as "not filed" — that would misstate the
        # state and lose the real issue. Exit 0 with the URL so the orchestrator
        # records the filing; on the next run the open-issue de-dupe (Step 1) is
        # the best-effort, single-layered recovery — it finds the still-open issue
        # and comments instead of re-filing, recovering the missing cooldown only
        # if that lookup itself succeeds (not a guarantee).
        rm -f "$OVERRIDES_TMP"
        echo "::error::meta-issue: issue WAS filed (${URL}) but its cooldown could not be recorded in ${OVERRIDES} — de-dupe will prevent a duplicate next run" >&2
    fi
fi

# ── Step 3: print URL to stdout ───────────────────────────────────────────────
printf '%s\n' "$URL"
