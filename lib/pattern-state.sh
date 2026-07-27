#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# pattern-state.sh — the retrospective loop's lifecycle reconciler for
# .devflow/learnings/overrides.json.
#
# It owns two operations against the overrides file:
#   migrate    — rewrite a schema_version:1 file in place to v2, converting ONLY
#                the loop's own `dismissed{}` entries (dismissed_by ==
#                "retrospective-weekly") into machine-owned `patterns{}` lifecycle
#                records, and preserving every hand-written `dismissed{}` entry
#                verbatim so a maintainer's escape valve survives.
#   reconcile  — for every meta-issue entry of every lifecycle record, resolve the
#                live GitHub issue state (one `--label Retrospective` prefetch plus
#                a per-number `gh issue view` fallback) and apply one of five
#                transitions, then derive each record's state from its entry set.
# `run` does migrate then reconcile (the SKILL's normal invocation).
#
# The v2 shape:
#   {
#     "schema_version": 2,
#     "patterns": {                       # machine-owned lifecycle map
#       "<slug>": {
#         "state": "filed|fixed|declined",
#         "fixed_at": "<iso8601|null>",   # the fix/closure timestamp compute-patterns.jq reads
#         "provenance": "<iso8601|null>", # carried from the v1 dismissed_at
#         "meta_issues": [                # the SET of issues filed for this slug
#           {"number": <int>, "url": "<https url>",
#            "state": "filed|fixed|declined", "closedAt": "<iso8601|null>",
#            "state_reason": "<COMPLETED|NOT_PLANNED|DUPLICATE|null>"}
#         ]
#       }
#     },
#     "dismissed": { ... }                # human-owned; written by NO filing path
#   }
#
# Reconcile transitions (complete by construction over GitHub's closed-issue
# stateReason domain plus the open state), per entry:
#   state == OPEN                → filed,    fixed_at cleared (null)
#   stateReason == COMPLETED     → fixed,    fixed_at = closedAt
#   stateReason == NOT_PLANNED   → declined, fixed_at = closedAt
#   stateReason == DUPLICATE     → declined, fixed_at = closedAt
#   closed w/ no or unrecognized stateReason → no transition + ::warning::
#
# Record state derives from the entry set: `filed` when any entry is filed;
# otherwise the state of the entry with the newest closedAt; record.fixed_at is
# that entry's fixed_at.
#
# Usage:
#   pattern-state.sh {migrate|reconcile|run} <overrides-path> [--limit N]
#
# Environment:
#   DEVFLOW_GH  override the gh binary (test stubbing). When unset/empty it is
#               resolved (execution-verified) via lib/resolve-gh.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# jq binary: resolved once via the sourced sibling resolver (issue #247).
# shellcheck source=resolve-jq.sh
. "$HERE/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

# gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins, so test stubs are untouched. resolve-gh.sh
# always returns rc 0, so this cannot abort under set -e.
# shellcheck source=resolve-gh.sh
. "$HERE/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

# The loop's own dismissed-entry writer marker — the migration converts only these.
_LOOP_WRITER="retrospective-weekly"

_usage() {
    echo "usage: pattern-state.sh {migrate|reconcile|run} <overrides-path> [--limit N]" >&2
    exit 2
}

# ── the directory holding a path, via bash builtins ───────────────────────────
# Never `dirname`: `lib/preflight.sh` does not guarantee it, and a missing
# non-preflight PATH tool does not fail — it yields empty, which would silently
# relocate every staging file below to the filesystem root.
_dir_of() {  # $1 = path
    local d="${1%/*}"
    [ "$d" = "$1" ] && d="."
    printf '%s' "$d"
}

# ── atomic write helper: write $2 (a file) over $1, mktemp-then-mv ─────────────
# On any failure emit an ::error:: naming the path and exit non-zero, leaving the
# previous file byte-unchanged.
_atomic_write() {  # $1 = dest path, $2 = source tmp holding new content
    local dest="$1" src="$2"
    local final
    # The staging file lives BESIDE the destination, never under $TMPDIR: `mv`
    # is an atomic rename only within one filesystem. On a runner where /tmp is
    # a separate filesystem (common in CI/cloud), a $TMPDIR staging file makes
    # the `mv` a copy-then-unlink that writes straight into the destination, so
    # a mid-copy failure (the disk-full case) leaves the previous file
    # TRUNCATED — exactly the "byte-unchanged on a failed write" guarantee this
    # helper exists to provide. A same-directory rename cannot half-apply.
    final="$(mktemp "$(_dir_of "$dest")/.overrides.XXXXXX")" \
      || { echo "::error::pattern-state: could not create a temp file beside ${dest}" >&2; return 1; }
    if ! cat "$src" > "$final"; then
        rm -f "$final"
        echo "::error::pattern-state: failed to stage the new contents for ${dest}" >&2
        return 1
    fi
    if ! mv "$final" "$dest"; then
        rm -f "$final"
        echo "::error::pattern-state: failed to write ${dest} (read-only filesystem, full disk, or bad path)" >&2
        return 1
    fi
    return 0
}

# ── migrate: schema_version 1 → 2, in place ───────────────────────────────────
# Idempotent: a v2 (or already-migrated) file is left byte-unchanged.
_migrate() {  # $1 = overrides path
    local ov="$1"
    # Absent or empty file: nothing to migrate (callers stub v2 themselves).
    [ -f "$ov" ] && [ -s "$ov" ] || return 0

    local ver
    ver="$("$DEVFLOW_JQ" -r '.schema_version // 1' "$ov" 2>/dev/null)" \
      || { echo "::error::pattern-state: ${ov} does not parse as JSON — migration aborted" >&2; return 1; }
    # Only v1 migrates; anything else (v2, or already-shaped) is a no-op so a
    # second run over a v2 file changes no byte.
    [ "$ver" = "1" ] || return 0

    local tmp
    # Staged beside the destination for the same reason _atomic_write is: the
    # whole write path stays on one filesystem, and none of it depends on
    # $TMPDIR being usable on the host.
    tmp="$(mktemp "$(_dir_of "$ov")/.overrides-mig.XXXXXX")" \
      || { echo "::error::pattern-state: could not create a temp file beside ${ov} during migration" >&2; return 1; }
    # Convert only loop-written dismissed entries into lifecycle records; keep
    # every hand-written entry verbatim in the v2 dismissed{} map.
    if ! "$DEVFLOW_JQ" --arg writer "$_LOOP_WRITER" '
        (.dismissed // {}) as $d
        | {
            schema_version: 2,
            patterns: (
              $d | to_entries
              | map(select(.value.dismissed_by == $writer))
              | map({
                  key: .key,
                  value: {
                    state: "filed",
                    fixed_at: null,
                    provenance: (.value.dismissed_at // null),
                    meta_issues: (
                      if (.value.meta_issue // "") != "" then
                        [{
                          number: ((.value.meta_issue | capture("/issues/(?<n>[0-9]+)")?) // {n:null} | .n | (if . == null then null else tonumber end)),
                          url: .value.meta_issue,
                          state: "filed",
                          closedAt: null
                        }]
                      else [] end
                    )
                  }
                })
              | from_entries
            ),
            dismissed: (
              $d | to_entries
              | map(select(.value.dismissed_by != $writer))
              | from_entries
            )
          }' "$ov" > "$tmp"; then
        rm -f "$tmp"
        echo "::error::pattern-state: migration jq transform failed for ${ov}" >&2
        return 1
    fi
    _atomic_write "$ov" "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# ── reconcile: refresh every meta-issue entry against live issue state ─────────
_reconcile() {  # $1 = overrides path, $2 = limit
    local ov="$1" limit="$2"
    [ -f "$ov" ] && [ -s "$ov" ] || return 0

    # Prefetch every Retrospective-labelled issue in one call. A non-zero gh exit
    # OR a non-JSON body is a wholesale failure: ::error:: + non-zero exit, no
    # transition applied to any pattern.
    local prefetch_raw
    prefetch_raw="$("$DEVFLOW_GH" issue list --label Retrospective --state all \
        --limit "$limit" --json number,state,stateReason,closedAt 2>/dev/null)" \
      || { echo "::error::pattern-state: the Retrospective prefetch failed (gh issue list exited non-zero)" >&2; return 1; }
    if ! printf '%s' "$prefetch_raw" | "$DEVFLOW_JQ" -e 'type == "array"' >/dev/null 2>&1; then
        echo "::error::pattern-state: the Retrospective prefetch body did not parse as a JSON array" >&2
        return 1
    fi

    # Prefetch map keyed by number → {state,stateReason,closedAt}.
    # A jq failure inside a command substitution is NOT caught by `set -e`: the
    # assignment succeeds with an empty value, which would silently degrade every
    # number to the by-number fallback with no diagnostic. Check explicitly.
    local prefetch_map
    prefetch_map="$(printf '%s' "$prefetch_raw" | "$DEVFLOW_JQ" -c '
        reduce .[] as $r ({}; . + {($r.number|tostring): {state: $r.state, stateReason: $r.stateReason, closedAt: $r.closedAt}})')" \
      || { echo "::error::pattern-state: could not build the prefetch map (jq exited non-zero) — no transition applied" >&2; return 1; }
    [ -n "$prefetch_map" ] \
      || { echo "::error::pattern-state: the prefetch map came out empty (jq produced no output) — no transition applied" >&2; return 1; }

    # Walk every slug's every entry, resolving each number. We drive the loop in
    # bash so an uncovered number can fall back to `gh issue view`. Each resolved
    # triple is appended to a jq object keyed by number; the final jq pass applies
    # the transitions and derives record states from that resolution map.
    local numbers
    numbers="$("$DEVFLOW_JQ" -r '
        (.patterns // {}) | to_entries[] | .value.meta_issues // [] | .[] | .number // empty' "$ov")" \
      || { echo "::error::pattern-state: could not enumerate the meta-issue numbers in ${ov} (jq exited non-zero) — no transition applied" >&2; return 1; }

    # Build a resolution map covering every number, using the prefetch first and
    # the by-number fallback for uncovered numbers. A number that resolves through
    # neither is recorded as unresolved so the transition pass can warn per slug.
    local resolved='{}'
    local num
    # De-duplicate the number list without a non-preflight tool: a bash associative
    # array. (tr/sed/sort/uniq are all barred from the SELECTION path.)
    declare -A _seen=()
    while IFS= read -r num; do
        [ -n "$num" ] || continue
        [ -n "${_seen[$num]:-}" ] && continue
        _seen[$num]=1
        local cover
        cover="$(printf '%s' "$prefetch_map" | "$DEVFLOW_JQ" -c --arg n "$num" '.[$n] // empty')" \
          || { echo "::error::pattern-state: prefetch lookup for meta-issue ${num} failed (jq exited non-zero) — no transition applied" >&2; return 1; }
        if [ -z "$cover" ]; then
            # By-number fallback — bounded by the number of records.
            cover="$("$DEVFLOW_GH" issue view "$num" --json number,state,stateReason,closedAt 2>/dev/null \
                     | "$DEVFLOW_JQ" -c '{state: .state, stateReason: .stateReason, closedAt: .closedAt}' 2>/dev/null || true)"
            if [ -z "$cover" ] || [ "$cover" = "null" ]; then
                resolved="$(printf '%s' "$resolved" | "$DEVFLOW_JQ" -c --arg n "$num" '. + {($n): {unresolved: true}}')" \
                  || { echo "::error::pattern-state: could not record meta-issue ${num} as unresolved (jq exited non-zero) — no transition applied" >&2; return 1; }
                continue
            fi
        fi
        resolved="$(printf '%s' "$resolved" | "$DEVFLOW_JQ" -c --arg n "$num" --argjson c "$cover" '. + {($n): $c}')" \
          || { echo "::error::pattern-state: could not record the resolution of meta-issue ${num} (jq exited non-zero) — no transition applied" >&2; return 1; }
    done <<< "$numbers"

    # Apply transitions + derive record states in one jq pass. Warnings for
    # no-url / unresolved / unrecognized-stateReason records are emitted to stderr
    # from a parallel jq pass so the transformed body stays on stdout only.
    printf '%s' "$resolved" | "$DEVFLOW_JQ" -r --slurpfile ov <(cat "$ov") '
        . as $res
        | ($ov[0].patterns // {}) | to_entries[]
        | .key as $slug | .value as $rec
        | ($rec.meta_issues // []) as $entries
        | if ($entries | length) == 0 then
            "::warning::pattern-state: pattern " + $slug + " has a lifecycle record with no meta-issue URL — no transition applied"
          else
            ( $entries[]
              | .number as $n
              | ($res[($n|tostring)] // {unresolved:true}) as $r
              | if ($n == null) or ($r.unresolved == true) then
                  "::warning::pattern-state: pattern " + $slug + " meta-issue " + (($n // "?")|tostring) + " could not be resolved via the prefetch or the by-number fallback — no transition applied"
                # The recognized set (open, plus the three closed stateReasons) all
                # transition cleanly — no warning; anything else is unrecognized.
                elif ($r.state == "OPEN") or (["COMPLETED","NOT_PLANNED","DUPLICATE"] | index($r.stateReason)) then empty
                else
                  "::warning::pattern-state: pattern " + $slug + " meta-issue #" + ($n|tostring) + " is closed with an unrecognized stateReason " + ($r.stateReason|tostring) + " — no transition applied"
                end
            )
          end' 1>&2 || true

    local tmp
    tmp="$(mktemp "$(_dir_of "$ov")/.overrides-rec.XXXXXX")" \
      || { echo "::error::pattern-state: could not create a temp file beside ${ov} during reconcile" >&2; return 1; }
    if ! printf '%s' "$resolved" | "$DEVFLOW_JQ" --slurpfile ov <(cat "$ov") '
        . as $res
        | $ov[0]
        | .patterns = (
            (.patterns // {}) | to_entries | map(
              .key as $slug | .value as $rec
              | .value.meta_issues = (
                  ($rec.meta_issues // []) | map(
                    . as $e
                    | ($res[(($e.number // "")|tostring)] // {unresolved:true}) as $r
                    | if ($e.number == null) or ($r.unresolved == true) then $e
                      elif ($r.state == "OPEN") then ($e + {state: "filed", closedAt: null, fixed_at: null, state_reason: null})
                      elif ($r.stateReason == "COMPLETED") then ($e + {state: "fixed", closedAt: $r.closedAt, fixed_at: $r.closedAt, state_reason: $r.stateReason})
                      elif (["NOT_PLANNED","DUPLICATE"] | index($r.stateReason)) then ($e + {state: "declined", closedAt: $r.closedAt, fixed_at: $r.closedAt, state_reason: $r.stateReason})
                      else $e end
                  )
                )
              # Derive the record state from the (now reconciled) entry set:
              # filed if any entry is filed; else the state of the entry with
              # the newest closedAt; record.fixed_at is that newest entry fixed_at.
              #
              # Deliberate trade-off (issue #788): an entry that could NOT be
              # resolved keeps its PRIOR state, so a record holding one genuinely
              # `fixed` entry plus one permanently-inaccessible `filed` entry
              # derives to `filed` and masks the fix for as long as the entry
              # stays unresolvable. That direction is chosen on purpose: deriving
              # the optimistic state instead would CLEAR the suppression of a
              # pattern whose issue may still be open, re-filing a duplicate. The
              # conservative direction only delays a re-file, and each unresolved
              # entry already fires a per-slug ::warning:: naming it, so the
              # condition is visible in the run log rather than silent.
              | .value as $rec2
              | ($rec2.meta_issues // []) as $es
              | if ($es | any(.state == "filed")) then
                  .value.state = "filed" | .value.fixed_at = null
                elif ($es | length) > 0 then
                  ($es | map(select(.closedAt != null)) | sort_by(.closedAt) | last) as $newest
                  | if $newest == null then .
                    else .value.state = $newest.state | .value.fixed_at = ($newest.fixed_at // $newest.closedAt)
                    end
                else . end
            ) | from_entries
          )' > "$tmp"; then
        rm -f "$tmp"
        echo "::error::pattern-state: reconcile jq transform failed for ${ov}" >&2
        return 1
    fi
    _atomic_write "$ov" "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# ── entrypoint ────────────────────────────────────────────────────────────────
[ $# -ge 2 ] || _usage
CMD="$1"; OVERRIDES="$2"; shift 2
LIMIT=200
while [ $# -gt 0 ]; do
    case "$1" in
        # `--limit` with no value must not reach `$2` under `set -u` (an
        # "unbound variable" abort diagnoses nothing); reject it here by name.
        --limit) [ $# -ge 2 ] || { echo "pattern-state: --limit requires a value" >&2; exit 2; }
                 LIMIT="$2"; shift 2 ;;
        *) echo "pattern-state: unknown argument: $1" >&2; exit 2 ;;
    esac
done
# Positive integer: `0` is all digits but is not positive, and `gh --limit 0` is
# itself an error — reject it here rather than shipping it to gh.
case "$LIMIT" in
    ''|*[!0-9]*|0|0[0-9]*) echo "pattern-state: --limit must be a positive integer (got '${LIMIT}')" >&2; exit 2 ;;
esac

case "$CMD" in
    migrate)   _migrate "$OVERRIDES" ;;
    reconcile) _reconcile "$OVERRIDES" "$LIMIT" ;;
    run)       _migrate "$OVERRIDES" && _reconcile "$OVERRIDES" "$LIMIT" ;;
    *) _usage ;;
esac
