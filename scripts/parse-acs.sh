#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Parse Acceptance Criteria from a GitHub issue body, classify post-merge.
#
# Pure bash + awk + jq re-implementation of parse-acs.py.
# Replicate parse-acs.py exactly — output must be byte-for-byte identical
# for md format and structurally equal for json format.
#
# Usage:
#   parse-acs.sh --issue ISSUE_NUMBER [--format md|json]
#   parse-acs.sh --body-file PATH    [--format md|json]
#
# Exit codes:
#   0  parsed and printed
#   1  body fetch failed
#   2  bad arguments
#
# --post-merge-probe TEXT   (TEST-ONLY flag) Print 1 if TEXT is post-merge, 0 otherwise.
#                           Used by lib/test/test_scripts.sh; not for production use.

set -euo pipefail

# ── Post-merge trigger phrases ─────────────────────────────────────────────
# VERBATIM copy from parse-acs.py POST_MERGE_TRIGGERS tuple.
# DO NOT reorder or paraphrase — the bash word-boundary matcher below
# depends on these exact strings.
POST_MERGE_TRIGGERS=(
  'after merge'
  'post-merge'
  'post-deploy'
  'after deploy'
  'open a pr'
  'mark it ready'
  'merge button'
  'mark the pr'
  'in production'
  'on staging'
  'live environment'
  'click to'
  'click the button'
  'verify manually'
  'manual verification'
  'monitor the deploy'
  'monitor logs'
  'monitor the logs'
  'verify in the ui'
  'via the github ui'
  'inspect logs'
  'watch the deploy'
  'compare runs'
  'the next run'
  'next deploy'
  'on a pr'
  'on a live pr'
  'on a real pr'
  'comment on the pr'
  'comment on a pr'
  'workflow run'
  'workflow runs'
  'artifact link'
)

# ── Word-boundary post-merge test ─────────────────────────────────────────
# Python uses \b...\b. Implemented portably with POSIX ERE in awk — NOT
# `grep -P`, which is GNU-only and absent on macOS/BSD (the repo deliberately
# avoids GNU-only flags; see lib/preflight.sh). The text is lowercased first,
# and every trigger phrase is [a-z0-9 ]+hyphen, so each is literal in ERE (no
# escaping needed). The (^|[^a-z0-9])…([^a-z0-9]|$) guards reproduce the
# [a-z0-9] word-boundary the phrases need (e.g. "monitor the logs" matches but
# "monitoring" does not; "workflow run" matches but "workflow runner" does not).
_is_post_merge() {
  local text="$1"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  local phrase
  for phrase in "${POST_MERGE_TRIGGERS[@]}"; do
    if printf '%s' "$lower" | awk -v p="$phrase" '
        BEGIN { pat = "(^|[^a-z0-9])" p "([^a-z0-9]|$)" }
        $0 ~ pat { found = 1 }
        END { exit (found ? 0 : 1) }'; then
      printf '1\n'
      return
    fi
  done
  printf '0\n'
}

# ── Section extraction ────────────────────────────────────────────────────
# Extract lines inside a section whose heading text equals NAME (case-insensitive,
# exact match — no trailing colon, no extra words). Heading level must be 2 or 3.
# Stops at the next heading whose level is <= section level.
# Output lines to stdout (empty if section not found).
_extract_section() {
  local body_file="$1"
  local name="$2"
  awk -v target_name="$name" '
    BEGIN {
      in_section   = 0
      section_level = 0
      # Build lowercase target for comparison
      target = tolower_str(target_name)
    }

    function tolower_str(s,    i, c, result) {
      result = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "A" && c <= "Z") {
          c = sprintf("%c", index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) + 96)
        }
        result = result c
      }
      return result
    }

    {
      line = $0

      # Check if this line is a heading (starts with one or more # then a space).
      # Use the 2-arg match() (POSIX); the 3-arg array form is a gawk-only
      # extension that crashes mawk/BSD awk. Heading depth is counted below.
      if (match(line, /^(#+)[[:space:]]/)) {
        n = 0
        while (substr(line, n + 1, 1) == "#") n++

        # heading text: everything after the #s and leading whitespace, trailing ws stripped
        heading_raw = substr(line, n + 1)
        sub(/^[[:space:]]+/, "", heading_raw)
        sub(/[[:space:]]+$/, "", heading_raw)
        heading_lower = tolower_str(heading_raw)

        if (!in_section) {
          if (heading_lower == target && (n == 2 || n == 3)) {
            in_section    = 1
            section_level = n
          }
          # Skip heading lines (do not print them)
          next
        } else {
          # Already in section: stop if this heading is at same or higher level
          if (n <= section_level) {
            exit
          }
          # Deeper heading: treat as content (print it)
          print line
          next
        }
      }

      # Non-heading line
      if (in_section) {
        print line
      }
    }
  ' "$body_file"
}

# ── Checkbox parse ────────────────────────────────────────────────────────
# Read checkbox lines from stdin; output TSV: ticked(0|1) TAB text
_parse_checkboxes() {
  while IFS= read -r line; do
    # Match: optional whitespace, - or *, space, [x/X/ ], space(s), text
    if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+\[([[:space:]xX])\][[:space:]]+(.*) ]]; then
      local box="${BASH_REMATCH[1]}"
      local text="${BASH_REMATCH[2]}"
      # Trim trailing whitespace from text
      text="${text%"${text##*[![:space:]]}"}"
      local ticked=0
      if [[ "$box" == "x" || "$box" == "X" ]]; then ticked=1; fi
      printf '%s\t%s\n' "$ticked" "$text"
    fi
  done
}

# ── Render a single md line ───────────────────────────────────────────────
_render_md_line() {
  local ticked="$1"
  local text="$2"
  local pm="$3"
  local box="[ ]"
  if [ "$ticked" = "1" ]; then box="[x]"; fi
  if [ "$pm" = "1" ] && [[ "$text" != *"(post-merge)"* ]]; then
    text="${text} (post-merge)"
  fi
  printf '%s\n' "- ${box} ${text}"
}

# ── Near-miss warning ─────────────────────────────────────────────────────
_warn_near_miss() {
  local have_items="$1"
  local body_file="$2"
  local canonical="$3"
  local needle="$4"
  if [ "$have_items" = "1" ]; then return; fi
  if grep -qiE "^#{2,3}[[:space:]]+.*${needle}" "$body_file" 2>/dev/null; then
    printf 'parse-acs.sh: no %s items parsed, but the body contains a heading that mentions '"'"'%s'"'"' — check that it is exactly '"'"'## %s'"'"' (any casing is fine, but no trailing colon or extra words).\n' \
      "$canonical" "$needle" "$canonical" >&2
  fi
}

# ── Tag items with post_merge ─────────────────────────────────────────────
# Input file: TSV ticked TAB text
# Output: TSV ticked TAB text TAB post_merge(0|1)
_tag_items() {
  local items_file="$1"
  [ ! -s "$items_file" ] && return
  while IFS=$'\t' read -r ticked text; do
    local pm
    pm="$(_is_post_merge "$text")"
    printf '%s\t%s\t%s\n' "$ticked" "$text" "$pm"
  done <"$items_file"
}

# ── Render md output ──────────────────────────────────────────────────────
_render_md() {
  local ac_file="$1"
  local tp_file="$2"
  local ac_count="$3"
  local tp_count="$4"

  if [ "$ac_count" -eq 0 ] && [ "$tp_count" -eq 0 ]; then
    printf '_(none provided in issue body)_\n'
    return
  fi

  local printed_ac=0
  if [ "$ac_count" -gt 0 ]; then
    while IFS=$'\t' read -r ticked text pm; do
      _render_md_line "$ticked" "$text" "$pm"
    done <"$ac_file"
    printed_ac=1
  fi

  if [ "$tp_count" -gt 0 ]; then
    if [ "$printed_ac" = "1" ]; then printf '\n'; fi
    while IFS=$'\t' read -r ticked text pm; do
      _render_md_line "$ticked" "$text" "$pm"
    done <"$tp_file"
  fi
}

# ── Items file to JSON array ──────────────────────────────────────────────
_items_to_json() {
  local items_file="$1"
  if [ ! -s "$items_file" ]; then
    printf '[]'
    return
  fi
  local result="["
  local first=1
  while IFS=$'\t' read -r ticked text pm; do
    local ticked_bool pm_bool
    [ "$ticked" = "1" ] && ticked_bool="true" || ticked_bool="false"
    [ "$pm" = "1" ] && pm_bool="true" || pm_bool="false"
    local obj
    obj="$(jq -n --arg text "$text" --argjson ticked "$ticked_bool" --argjson pm "$pm_bool" \
      '{text: $text, ticked: $ticked, post_merge: $pm}')"
    if [ "$first" = "1" ]; then
      result="${result}${obj}"
      first=0
    else
      result="${result},${obj}"
    fi
  done <"$items_file"
  result="${result}]"
  printf '%s' "$result"
}

# ── Render json output ────────────────────────────────────────────────────
_render_json() {
  local ac_file="$1"
  local tp_file="$2"
  local ac_json tp_json
  ac_json="$(_items_to_json "$ac_file")"
  tp_json="$(_items_to_json "$tp_file")"
  jq -n \
    --argjson ac "$ac_json" \
    --argjson tp "$tp_json" \
    '{acceptance_criteria: $ac, test_plan: $tp}'
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  local issue=""
  local body_file=""
  local format="md"
  local post_merge_probe=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)
        [ -n "$body_file" ] && { printf 'parse-acs.sh: --issue and --body-file are mutually exclusive\n' >&2; exit 2; }
        [ -z "${2:-}" ] && { printf 'parse-acs.sh: --issue requires a value\n' >&2; exit 2; }
        issue="$2"; shift 2 ;;
      --body-file)
        [ -n "$issue" ] && { printf 'parse-acs.sh: --issue and --body-file are mutually exclusive\n' >&2; exit 2; }
        [ -z "${2:-}" ] && { printf 'parse-acs.sh: --body-file requires a value\n' >&2; exit 2; }
        body_file="$2"; shift 2 ;;
      --format)
        [ -z "${2:-}" ] && { printf 'parse-acs.sh: --format requires md or json\n' >&2; exit 2; }
        format="$2"
        case "$format" in md|json) ;; *) printf 'parse-acs.sh: --format must be md or json\n' >&2; exit 2 ;; esac
        shift 2 ;;
      --post-merge-probe)
        # TEST-ONLY: prints 1/0 and exits
        [ -z "${2:-}" ] && { printf 'parse-acs.sh: --post-merge-probe requires text\n' >&2; exit 2; }
        post_merge_probe="$2"; shift 2 ;;
      *)
        printf 'parse-acs.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  # Handle test-only probe before source-requirement check
  if [ -n "$post_merge_probe" ]; then
    _is_post_merge "$post_merge_probe"
    exit 0
  fi

  # Require exactly one source
  if [ -z "$issue" ] && [ -z "$body_file" ]; then
    printf 'parse-acs.sh: one of --issue or --body-file is required\n' >&2
    exit 2
  fi

  # Fetch or read body into a file
  local tmpbody=""
  if [ -n "$issue" ]; then
    tmpbody="$(mktemp)"
    local gh_err
    gh_err="$(mktemp)"
    if ! gh issue view "$issue" --json body -q .body >"$tmpbody" 2>"$gh_err"; then
      printf 'parse-acs.sh: gh issue view failed: %s\n' "$(cat "$gh_err")" >&2
      rm -f "$tmpbody" "$gh_err"
      exit 1
    fi
    rm -f "$gh_err"
    body_file="$tmpbody"
  fi

  # Extract sections to temp files
  local ac_raw_tmp tp_raw_tmp
  ac_raw_tmp="$(mktemp)"
  tp_raw_tmp="$(mktemp)"
  _extract_section "$body_file" "Acceptance Criteria" >"$ac_raw_tmp"
  _extract_section "$body_file" "Test Plan"           >"$tp_raw_tmp"

  # Parse checkboxes
  local ac_items_tmp tp_items_tmp
  ac_items_tmp="$(mktemp)"
  tp_items_tmp="$(mktemp)"
  _parse_checkboxes <"$ac_raw_tmp" >"$ac_items_tmp"
  _parse_checkboxes <"$tp_raw_tmp" >"$tp_items_tmp"

  # Count items
  local ac_count=0 tp_count=0
  if [ -s "$ac_items_tmp" ]; then ac_count="$(wc -l <"$ac_items_tmp" | tr -d ' \t')"; fi
  if [ -s "$tp_items_tmp" ]; then tp_count="$(wc -l <"$tp_items_tmp" | tr -d ' \t')"; fi

  # Near-miss warnings
  local ac_has=0 tp_has=0
  if [ "$ac_count" -gt 0 ]; then ac_has=1; fi
  if [ "$tp_count" -gt 0 ]; then tp_has=1; fi
  _warn_near_miss "$ac_has" "$body_file" "Acceptance Criteria" "acceptance"
  _warn_near_miss "$tp_has" "$body_file" "Test Plan" "test plan"

  # Tag items with post_merge
  local ac_tagged_tmp tp_tagged_tmp
  ac_tagged_tmp="$(mktemp)"
  tp_tagged_tmp="$(mktemp)"
  _tag_items "$ac_items_tmp" >"$ac_tagged_tmp"
  _tag_items "$tp_items_tmp" >"$tp_tagged_tmp"

  # Render
  if [ "$format" = "md" ]; then
    _render_md "$ac_tagged_tmp" "$tp_tagged_tmp" "$ac_count" "$tp_count"
  else
    _render_json "$ac_tagged_tmp" "$tp_tagged_tmp"
  fi

  # Cleanup
  rm -f "$ac_raw_tmp" "$tp_raw_tmp" "$ac_items_tmp" "$tp_items_tmp" \
        "$ac_tagged_tmp" "$tp_tagged_tmp"
  if [ -n "$tmpbody" ]; then rm -f "$tmpbody"; fi
}

main "$@"
