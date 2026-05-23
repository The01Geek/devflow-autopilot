#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# DevFlow workpad helper — bash + jq + awk port of workpad.py.
#
# Usage:
#   workpad.sh id      ISSUE
#   workpad.sh body    COMMENT_ID
#   workpad.sh patch   COMMENT_ID BODY_FILE
#   workpad.sh create  ISSUE BODY_FILE
#   workpad.sh now
#   workpad.sh update  ISSUE [mutations...] [--dry-print]
#
# `id` exits 1 with empty stdout when no workpad exists yet.
# `update --dry-print` prints the mutated body to stdout INSTEAD of PATCHing
# (test-only seam; document do not rely on in production).
#
# All subcommands shell out to `gh` for GitHub API access.
# The workpad marker is read from .devflow/config.json via config-get.sh,
# falling back to the built-in default <!-- devflow:workpad --> on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK_LIB="${SCRIPT_DIR}/../lib/workpad-sections.awk"
CONFIG_GET="${SCRIPT_DIR}/config-get.sh"

_DEFAULT_MARKER='<!-- devflow:workpad -->'

# ─── helpers ────────────────────────────────────────────────────────────────

_die() {
    printf 'workpad.sh %s\n' "$*" >&2
    exit 1
}

_repo_full() {
    gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null \
        || _die "repo lookup: gh repo view failed"
}

_workpad_marker() {
    local marker
    marker="$("${CONFIG_GET}" '.claude.workpad_marker' "${_DEFAULT_MARKER}" 2>/dev/null)" \
        || marker="${_DEFAULT_MARKER}"
    [ -n "${marker}" ] || marker="${_DEFAULT_MARKER}"
    printf '%s' "${marker}"
}

# ─── cmd_now ────────────────────────────────────────────────────────────────
cmd_now() {
    jq -rn 'now | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# ─── cmd_id ─────────────────────────────────────────────────────────────────
cmd_id() {
    local issue="$1"
    local marker repo page items id body
    marker="$(_workpad_marker)"
    repo="$(_repo_full)"
    page=1
    while true; do
        items="$(gh api "/repos/${repo}/issues/${issue}/comments?page=${page}&per_page=100" 2>/dev/null)" \
            || _die "id: gh api call failed for issue ${issue}"
        # Scan items for first comment whose body starts with the marker.
        id="$(printf '%s' "${items}" | jq -r --arg m "${marker}" \
            'first(.[] | select((.body // "") | startswith($m)) | .id | tostring) // ""')"
        if [ -n "${id}" ]; then
            printf '%s\n' "${id}"
            return 0
        fi
        local count
        count="$(printf '%s' "${items}" | jq 'length')"
        if [ "${count}" -lt 100 ]; then
            break
        fi
        page=$((page + 1))
    done
    exit 1
}

# ─── cmd_body ───────────────────────────────────────────────────────────────
cmd_body() {
    local comment_id="$1"
    local repo
    repo="$(_repo_full)"
    gh api "/repos/${repo}/issues/comments/${comment_id}" --jq '.body' 2>/dev/null \
        || _die "body: gh api call failed for comment ${comment_id}"
}

# ─── cmd_patch ──────────────────────────────────────────────────────────────
cmd_patch() {
    local comment_id="$1" body_file="$2"
    [ -f "${body_file}" ] || _die "patch: body file not found: ${body_file}"
    local repo
    repo="$(_repo_full)"
    gh api -X PATCH "/repos/${repo}/issues/comments/${comment_id}" \
        -F "body=@${body_file}" --jq '.body' 2>/dev/null \
        || _die "patch: gh api PATCH failed for comment ${comment_id}"
}

# ─── cmd_create ─────────────────────────────────────────────────────────────
cmd_create() {
    local issue="$1" body_file="$2"
    [ -f "${body_file}" ] || _die "create: body file not found: ${body_file}"
    local out
    out="$(gh issue comment "${issue}" --body-file "${body_file}" 2>/dev/null)" \
        || _die "create: gh issue comment failed for issue ${issue}"
    # Extract comment id from URL like https://github.com/.../issues/1#issuecomment-123
    local id
    id="$(printf '%s' "${out}" | grep -oE '#issuecomment-[0-9]+' | tail -1 | grep -oE '[0-9]+')"
    if [ -n "${id}" ]; then
        printf '%s\n' "${id}"
        return 0
    fi
    # Fail loud — matches workpad.py behavior exactly.
    printf 'workpad.sh create: gh did not print a comment URL; the workpad may or may not have been posted. Inspect the issue manually before retrying. Raw stdout:\n' >&2
    printf '%s\n' "${out}" >&2
    exit 1
}

# ─── cmd_update ─────────────────────────────────────────────────────────────
# Parses mutation flags, applies atomically, PATCHes (or --dry-print).

cmd_update() {
    local issue="$1"
    shift

    # ── parse mutation flags ──────────────────────────────────────────────────
    local opt_status="" opt_branch="" opt_dry_print=0
    local -a opt_tick_plan opt_tick_ac opt_note opt_reflection
    opt_tick_plan=()
    opt_tick_ac=()
    opt_note=()
    opt_reflection=()
    local opt_rewrite_ac_old="" opt_rewrite_ac_new="" opt_rewrite_ac_set=0
    local opt_replace_plan_file="" opt_replace_acs_file="" opt_set_repro_file=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --status)
                [ $# -ge 2 ] || _die "update: --status requires a value"
                opt_status="$2"; shift 2 ;;
            --branch)
                [ $# -ge 2 ] || _die "update: --branch requires a value"
                opt_branch="$2"; shift 2 ;;
            --tick-plan)
                [ $# -ge 2 ] || _die "update: --tick-plan requires a value"
                opt_tick_plan+=("$2"); shift 2 ;;
            --tick-ac)
                [ $# -ge 2 ] || _die "update: --tick-ac requires a value"
                opt_tick_ac+=("$2"); shift 2 ;;
            --rewrite-ac)
                [ $# -ge 3 ] || _die "update: --rewrite-ac requires OLD and NEW"
                opt_rewrite_ac_old="$2"; opt_rewrite_ac_new="$3"
                opt_rewrite_ac_set=1; shift 3 ;;
            --note)
                [ $# -ge 2 ] || _die "update: --note requires a value"
                opt_note+=("$2"); shift 2 ;;
            --reflection)
                [ $# -ge 2 ] || _die "update: --reflection requires a value"
                opt_reflection+=("$2"); shift 2 ;;
            --replace-plan-file)
                [ $# -ge 2 ] || _die "update: --replace-plan-file requires a value"
                opt_replace_plan_file="$2"; shift 2 ;;
            --replace-acs-file)
                [ $# -ge 2 ] || _die "update: --replace-acs-file requires a value"
                opt_replace_acs_file="$2"; shift 2 ;;
            --set-reproduction-file)
                [ $# -ge 2 ] || _die "update: --set-reproduction-file requires a value"
                opt_set_repro_file="$2"; shift 2 ;;
            --dry-print)
                opt_dry_print=1; shift ;;
            *)
                _die "update: unknown flag: $1" ;;
        esac
    done

    # ── validate file args BEFORE fetching anything (atomicity) ──────────────
    local f
    for f in "${opt_replace_plan_file}" "${opt_replace_acs_file}" "${opt_set_repro_file}"; do
        [ -z "${f}" ] && continue
        [ -f "${f}" ] || { printf 'workpad.sh update: could not read file %s\n' "${f}" >&2; exit 1; }
    done

    # ── find comment id ───────────────────────────────────────────────────────
    local marker repo comment_id page items cid body
    marker="$(_workpad_marker)"
    repo="$(_repo_full)"
    comment_id=""
    page=1
    while true; do
        items="$(gh api "/repos/${repo}/issues/${issue}/comments?page=${page}&per_page=100" 2>/dev/null)" \
            || _die "update id-lookup: gh api call failed"
        cid="$(printf '%s' "${items}" | jq -r --arg m "${marker}" \
            'first(.[] | select((.body // "") | startswith($m)) | .id | tostring) // ""')"
        if [ -n "${cid}" ]; then
            comment_id="${cid}"
            break
        fi
        local count
        count="$(printf '%s' "${items}" | jq 'length')"
        if [ "${count}" -lt 100 ]; then
            break
        fi
        page=$((page + 1))
    done

    if [ -z "${comment_id}" ]; then
        printf 'workpad.sh update: no workpad found for issue #%s; call `workpad.sh create` first\n' \
            "${issue}" >&2
        exit 1
    fi

    # ── fetch live body ───────────────────────────────────────────────────────
    body="$(gh api "/repos/${repo}/issues/comments/${comment_id}" --jq '.body' 2>/dev/null)" \
        || _die "update body-fetch: gh api call failed"

    # ── apply mutations (atomically to working copy) ──────────────────────────
    local now
    now="$(cmd_now)"

    local err_tmp
    err_tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${err_tmp}'" EXIT

    # Helper: run one awk mutation; on failure capture stderr and fail fast.
    _awk_mutate() {
        local result
        if ! result="$(printf '%s' "${body}" \
            | awk -f "${AWK_LIB}" "$@" 2>"${err_tmp}")"; then
            local msg
            msg="$(cat "${err_tmp}")"
            printf 'workpad.sh update: %s\n' "${msg}" >&2
            exit 1
        fi
        body="${result}"
    }

    # Front-matter mutations (inline sed-E substitutions).
    if [ -n "${opt_status}" ]; then
        local new_body
        new_body="$(printf '%s' "${body}" \
            | sed -E "s/^(\*\*Status:\*\*)[[:space:]]+.*$/\1 ${opt_status}/")"
        # Verify substitution happened (grep for the new line).
        if ! printf '%s' "${new_body}" | grep -qE '^\*\*Status:\*\*[[:space:]]+.+$'; then
            printf 'workpad.sh update: Status line not found in workpad\n' >&2; exit 1
        fi
        # If unchanged from original, it means pattern wasn't there.
        if [ "${new_body}" = "${body}" ] && ! printf '%s' "${body}" | grep -qE '^\*\*Status:\*\*[[:space:]]+'; then
            printf 'workpad.sh update: Status line not found in workpad\n' >&2; exit 1
        fi
        body="${new_body}"
    fi

    if [ -n "${opt_branch}" ]; then
        local new_body
        new_body="$(printf '%s' "${body}" \
            | sed -E "s/^(\*\*Branch:\*\*)[[:space:]]+.*$/\1 \`${opt_branch}\`/")"
        if [ "${new_body}" = "${body}" ] && ! printf '%s' "${body}" | grep -qE '^\*\*Branch:\*\*[[:space:]]+'; then
            printf 'workpad.sh update: Branch line not found in workpad\n' >&2; exit 1
        fi
        body="${new_body}"
    fi

    # Always refresh Last updated.
    local new_body
    new_body="$(printf '%s' "${body}" \
        | sed -E "s/^(\*\*Last updated:\*\*)[[:space:]]+.*$/\1 ${now}/")"
    if [ "${new_body}" = "${body}" ] && ! printf '%s' "${body}" | grep -qE '^\*\*Last updated:\*\*[[:space:]]+'; then
        printf 'workpad.sh update: Last updated line not found in workpad\n' >&2; exit 1
    fi
    body="${new_body}"

    # tick-plan
    local t
    for t in "${opt_tick_plan[@]+"${opt_tick_plan[@]}"}"; do
        _awk_mutate -v CMD=tick -v SECTION="Plan" -v SUBSTR="${t}"
    done

    # tick-ac
    for t in "${opt_tick_ac[@]+"${opt_tick_ac[@]}"}"; do
        _awk_mutate -v CMD=tick -v SECTION="Acceptance Criteria" -v SUBSTR="${t}"
    done

    # rewrite-ac
    if [ "${opt_rewrite_ac_set}" -eq 1 ]; then
        _awk_mutate -v CMD=rewrite -v SECTION="Acceptance Criteria" \
            -v OLDSUBSTR="${opt_rewrite_ac_old}" -v NEWTEXT="${opt_rewrite_ac_new}"
    fi

    # replace-plan-file
    if [ -n "${opt_replace_plan_file}" ]; then
        _awk_mutate -v CMD=set_content -v SECTION="Plan" \
            -v CONTENT_FILE="${opt_replace_plan_file}"
    fi

    # replace-acs-file
    if [ -n "${opt_replace_acs_file}" ]; then
        _awk_mutate -v CMD=set_content -v SECTION="Acceptance Criteria" \
            -v CONTENT_FILE="${opt_replace_acs_file}"
    fi

    # set-reproduction-file
    if [ -n "${opt_set_repro_file}" ]; then
        # Check if Reproduction section exists.
        local has_repro
        has_repro="$(printf '%s' "${body}" \
            | awk 'tolower($0) ~ /^## reproduction[[:space:]]*$/ {found=1} END {print found+0}')"
        if [ "${has_repro}" -eq 1 ]; then
            _awk_mutate -v CMD=set_content -v SECTION="Reproduction" \
                -v CONTENT_FILE="${opt_set_repro_file}"
        else
            _awk_mutate -v CMD=insert_after -v AFTER_SECTION="Acceptance Criteria" \
                -v NEW_HEADING="## Reproduction" -v CONTENT_FILE="${opt_set_repro_file}"
        fi
    fi

    # notes (repeatable)
    for t in "${opt_note[@]+"${opt_note[@]}"}"; do
        _awk_mutate -v CMD=append_note -v SECTION="Decisions / Notes" \
            -v TIMESTAMP="${now}" -v NOTE="${t}"
    done

    # reflections (repeatable)
    for t in "${opt_reflection[@]+"${opt_reflection[@]}"}"; do
        _awk_mutate -v CMD=append_bullet -v SECTION="Devflow Reflection" \
            -v TEXT="${t}"
    done

    # ── dry-print or PATCH ────────────────────────────────────────────────────
    if [ "${opt_dry_print}" -eq 1 ]; then
        printf '%s' "${body}"
        return 0
    fi

    local tmp
    tmp="$(mktemp --suffix=.md)"
    # shellcheck disable=SC2064
    trap "rm -f '${err_tmp}' '${tmp}'" EXIT
    printf '%s' "${body}" >"${tmp}"

    gh api -X PATCH "/repos/${repo}/issues/comments/${comment_id}" \
        -F "body=@${tmp}" --jq '.body' 2>/dev/null \
        || _die "update patch: gh api PATCH failed"

    rm -f "${tmp}" "${err_tmp}"
}

# ─── dispatch ────────────────────────────────────────────────────────────────
_usage() {
    cat >&2 <<'EOF'
Usage: workpad.sh SUBCOMMAND [args...]

Subcommands:
  id      ISSUE               Print workpad comment ID (exit 1 if absent)
  body    COMMENT_ID          Print workpad comment body
  patch   COMMENT_ID FILE     PATCH body from file; print new body
  create  ISSUE FILE          Create workpad comment; print new ID
  now                         UTC ISO-8601 timestamp
  update  ISSUE [flags...]    Apply atomic mutations and PATCH

update flags (combinable):
  --status VAL                Replace **Status:** line
  --branch VAL                Replace **Branch:** line (wraps in backticks)
  --tick-plan TEXT            Tick one unticked Plan checkbox (repeatable)
  --tick-ac TEXT              Tick one unticked AC checkbox (repeatable)
  --rewrite-ac OLD NEW        Rewrite one AC checkbox label
  --note TEXT                 Append timestamped note (repeatable)
  --reflection TEXT           Append reflection bullet (repeatable)
  --replace-plan-file FILE    Replace Plan content from file
  --replace-acs-file FILE     Replace AC content from file
  --set-reproduction-file FILE Set/insert Reproduction section from file
  --dry-print                 Print mutated body instead of PATCHing [test-only]
EOF
    exit 2
}

[ $# -ge 1 ] || _usage
CMD="$1"; shift

case "${CMD}" in
    id)     [ $# -eq 1 ] || _usage; cmd_id "$1" ;;
    body)   [ $# -eq 1 ] || _usage; cmd_body "$1" ;;
    patch)  [ $# -eq 2 ] || _usage; cmd_patch "$1" "$2" ;;
    create) [ $# -eq 2 ] || _usage; cmd_create "$1" "$2" ;;
    now)    [ $# -eq 0 ] || _usage; cmd_now ;;
    update) [ $# -ge 1 ] || _usage; cmd_update "$@" ;;
    *)      _usage ;;
esac
