#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# file-deferrals.sh — DevFlow follow-up filer for review-and-fix deferrals.
#
# The /implement skill's Phase 4.0.5 reads the deferrals manifest produced by
# /devflow:review-and-fix (at `.devflow/tmp/review/<slug>/deferrals.json`), files
# one follow-up GitHub issue per source file, and rewrites the manifest with
# the assigned issue numbers + deterministic deferral IDs. The /devflow:review
# verdict engine then matches these entries against the PR-body block to
# demote already-acknowledged findings.
#
# Usage:
#   file-deferrals.sh --source-issue N --pr M --manifest PATH [--dry-run]
#
# Exit codes:
#   0  At least one group of findings was filed successfully (or --dry-run).
#   1  Nothing was filed (every group failed, or input was invalid).
#   2  Bad arguments / unusable manifest.
#
# Hidden test seams (test-only):
#   --area-probe PATH          Print the derived area for PATH and exit 0.
#   --id-probe FILE SYM KIND SUMMARY  Print the deferral ID and exit 0.
#   --line-range-probe JSON_ARRAY     Print the formatted line range and exit 0.

set -u

# ── portability: sha256 helper ───────────────────────────────────────────────
_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

# ── error/exit helpers ───────────────────────────────────────────────────────
_fail() {
  local msg="$1" code="${2:-1}"
  printf 'file-deferrals.sh: %s\n' "$msg" >&2
  exit "$code"
}

# ── ISO-8601 UTC timestamp ───────────────────────────────────────────────────
_now_iso() {
  jq -rn 'now|gmtime|strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# ── gh login (filed_by) ──────────────────────────────────────────────────────
_gh_login() {
  local rc_info="no-binary" stderr_info="" rc
  if command -v gh >/dev/null 2>&1; then
    local gh_out gh_err
    gh_out="$(gh api user --jq .login 2>/tmp/_dfr_gh_err)"; rc=$?
    gh_err="$(head -c 120 /tmp/_dfr_gh_err 2>/dev/null || true)"
    rm -f /tmp/_dfr_gh_err
    if [ "$rc" -eq 0 ] && [ -n "$gh_out" ]; then
      printf '%s' "$gh_out"
      return 0
    fi
    rc_info="$rc"
    stderr_info="$gh_err"
  fi
  printf 'file-deferrals.sh: gh api user unavailable (rc=%s, stderr=%s), falling back to GITHUB_ACTOR\n' \
    "$rc_info" "$stderr_info" >&2
  local actor="${GITHUB_ACTOR:-}"
  actor="$(printf '%s' "$actor" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -n "$actor" ]; then
    printf '%s' "$actor"
    return 0
  fi
  printf 'file-deferrals.sh: GITHUB_ACTOR unset, filed_by will be '\''(unknown)'\''\n' >&2
  printf '(unknown)'
}

# ── _derive_area ─────────────────────────────────────────────────────────────
# First non-src-equivalent segment, or basename without extension.
#
# Examples:
#   src/example/transport/http.py -> example
#   src/transport/http.py         -> transport
#   pyproject.toml                -> pyproject
#   scripts/foo/bar.sh            -> scripts
_derive_area() {
  local file_path="$1"
  # Split path into parts (portable via awk)
  local area
  area="$(printf '%s' "$file_path" | awk '
  BEGIN { FS="/" }
  {
    # Collect non-empty parts
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i != "") parts[n++] = $i
    }
    # Check for src-like first segment
    src_like["src"] = 1; src_like["lib"] = 1; src_like["pkg"] = 1
    src_like["app"] = 1; src_like["source"] = 1; src_like["sources"] = 1
    found = ""
    for (i = 0; i < n; i++) {
      lo = tolower(parts[i])
      if (lo in src_like && i + 1 < n) {
        found = parts[i+1]
        break
      }
    }
    if (found != "") { print found; exit }
    # More than 1 segment: return first
    if (n > 1) { print parts[0]; exit }
    # Single segment: return stem (basename without last extension)
    base = parts[0]
    # Remove last extension
    if (match(base, /\.[^.]+$/)) {
      stem = substr(base, 1, RSTART - 1)
    } else {
      stem = base
    }
    if (stem == "") { print "general" } else { print stem }
  }
  ')"
  printf '%s' "$area"
}

# ── _compute_id ──────────────────────────────────────────────────────────────
# Deterministic ID: dfr- + first 6 hex chars of sha256(file|symbol|kind|summary.strip())
_compute_id() {
  local file="$1" symbol="$2" kind="$3" summary="$4"
  # Strip leading/trailing whitespace from summary
  summary="$(printf '%s' "$summary" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  local payload="${file}|${symbol}|${kind}|${summary}"
  local hex
  hex="$(printf '%s' "$payload" | _sha | cut -c1-6)"
  printf 'dfr-%s' "$hex"
}

# ── _format_line_range ────────────────────────────────────────────────────────
# [a,b]→a-b, [a,a]→a, otherwise (unspecified)
_format_line_range() {
  local lr_json="$1"
  # Must be a 2-element JSON array
  local len
  len="$(printf '%s' "$lr_json" | jq -r 'if type == "array" and length == 2 then length else 0 end' 2>/dev/null || echo 0)"
  if [ "$len" != "2" ]; then
    printf '(unspecified)'
    return
  fi
  local start end
  start="$(printf '%s' "$lr_json" | jq -r '.[0]')"
  end="$(printf '%s' "$lr_json" | jq -r '.[1]')"
  if [ "$start" = "$end" ]; then
    printf '%s' "$start"
  else
    printf '%s-%s' "$start" "$end"
  fi
}

# ── _render_issue_body ────────────────────────────────────────────────────────
# Reproduces the exact body template from file-deferrals.py.
# The 'PR #<n>' substring on the first line is validated by the verdict engine.
# Do not reformat without updating the matcher.
_render_issue_body() {
  local findings_json="$1" source_issue="$2" pr_number="$3"

  printf 'Carried forward from the /implement run on #%s (PR #%s).\n' \
    "$source_issue" "$pr_number"
  printf '\n'
  printf 'The following review-agent findings were surfaced during PR review '
  printf 'but deferred under the Scope-Acknowledged Findings contract. They are '
  printf 'tracked here for follow-up resolution. Closing this issue invalidates '
  printf 'the related deferral and forces re-verification on the next '
  printf '/devflow:review run.\n'
  printf '\n'
  printf '## Findings\n'
  printf '\n'

  # Iterate each finding in the JSON array
  local count
  count="$(printf '%s' "$findings_json" | jq 'length')"
  local i=0
  while [ "$i" -lt "$count" ]; do
    local finding
    finding="$(printf '%s' "$findings_json" | jq ".[$i]")"

    local severity agent file_ symbol kind summary category explanation
    severity="$(printf '%s' "$finding" | jq -r '.severity // "Unknown"')"
    agent="$(printf '%s' "$finding" | jq -r '.agent // "unknown-agent"')"
    file_="$(printf '%s' "$finding" | jq -r '.file // "(unknown)"')"
    symbol="$(printf '%s' "$finding" | jq -r 'if .symbol == null or .symbol == "" then "(unspecified)" else .symbol end')"
    kind="$(printf '%s' "$finding" | jq -r '.kind // "(unspecified)"')"
    summary="$(printf '%s' "$finding" | jq -r '(.summary // "") | ltrimstr(" ") | rtrimstr(" ")')"
    # strip all whitespace using shell
    summary="$(printf '%s' "$summary" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    category="$(printf '%s' "$finding" | jq -r '.category // "(unspecified)"')"
    explanation="$(printf '%s' "$finding" | jq -r '(.explanation // "") | ltrimstr(" ") | rtrimstr(" ")')"
    explanation="$(printf '%s' "$explanation" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Format line range
    local lr_json line_str
    lr_json="$(printf '%s' "$finding" | jq '.line_range // null')"
    line_str="$(_format_line_range "$lr_json")"

    printf '### %s — %s\n' "$severity" "$agent"
    printf '**File**: %s:%s\n' "$file_" "$line_str"
    printf '**Symbol**: %s\n' "$symbol"
    printf '**Kind**: %s\n' "$kind"
    printf '\n'
    printf '%s\n' "$summary"
    printf '\n'
    printf '**Why deferred**: %s — %s\n' "$category" "$explanation"
    printf '\n'

    i=$((i + 1))
  done

  printf -- '---\n'
  printf 'Filed automatically by devflow-implement.'
}

# ── _issue_title ──────────────────────────────────────────────────────────────
_issue_title() {
  local area="$1" file_path="$2" source_issue="$3"
  printf '%s: deferred review findings in %s (carried from #%s)' \
    "$area" "$file_path" "$source_issue"
}

# ── atomic manifest write ─────────────────────────────────────────────────────
_write_manifest_atomic() {
  local path="$1" data="$2"
  local tmp="${path}.tmp"
  printf '%s\n' "$data" >"$tmp"
  mv "$tmp" "$path"
}

# ════════════════════════════════════════════════════════════════════════════════
# Test probe entry points (hidden test seams, not for production use)
# ════════════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--area-probe" ]; then
  [ $# -ge 2 ] || _fail "usage: --area-probe PATH" 2
  _derive_area "$2"
  printf '\n'
  exit 0
fi

if [ "${1:-}" = "--id-probe" ]; then
  [ $# -ge 5 ] || _fail "usage: --id-probe FILE SYMBOL KIND SUMMARY" 2
  _compute_id "$2" "$3" "$4" "$5"
  printf '\n'
  exit 0
fi

if [ "${1:-}" = "--line-range-probe" ]; then
  [ $# -ge 2 ] || _fail "usage: --line-range-probe JSON_ARRAY" 2
  _format_line_range "$2"
  printf '\n'
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ════════════════════════════════════════════════════════════════════════════════
source_issue=""
pr_number=""
manifest_path=""
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --source-issue) source_issue="$2"; shift 2 ;;
    --pr)           pr_number="$2";    shift 2 ;;
    --manifest)     manifest_path="$2"; shift 2 ;;
    --dry-run)      dry_run=1;          shift ;;
    --) shift; break ;;
    -*) _fail "unknown option: $1" 2 ;;
    *)  _fail "unexpected argument: $1" 2 ;;
  esac
done

[ -n "$source_issue" ] || _fail "missing required argument: --source-issue" 2
[ -n "$pr_number" ]    || _fail "missing required argument: --pr" 2
[ -n "$manifest_path" ] || _fail "missing required argument: --manifest" 2

# Validate numeric args
case "$source_issue" in
  ''|*[!0-9]*) _fail "--source-issue must be a positive integer" 2 ;;
esac
case "$pr_number" in
  ''|*[!0-9]*) _fail "--pr must be a positive integer" 2 ;;
esac

# ════════════════════════════════════════════════════════════════════════════════
# Validate manifest
# ════════════════════════════════════════════════════════════════════════════════
[ -f "$manifest_path" ] || _fail "manifest not found: $manifest_path" 2

# Parse JSON
manifest_json=""
if ! manifest_json="$(jq '.' "$manifest_path" 2>/dev/null)"; then
  _fail "manifest is not valid JSON: $manifest_path" 2
fi

# Check schema_version
schema_ver="$(printf '%s' "$manifest_json" | jq -r '.schema_version // "null"')"
if [ "$schema_ver" != "1" ]; then
  _fail "manifest schema_version=${schema_ver} unsupported (expected 1)" 2
fi

# Check non-empty deferrals
deferrals_count="$(printf '%s' "$manifest_json" | jq '.deferrals | length')"
if [ "$deferrals_count" -eq 0 ] 2>/dev/null || [ -z "$deferrals_count" ] || [ "$deferrals_count" = "null" ]; then
  _fail "manifest contains no deferrals — nothing to file" 2
fi

# Refuse to re-file if any deferral already has follow_up
has_follow_up="$(printf '%s' "$manifest_json" | jq '[.deferrals[] | select(.follow_up != null)] | length')"
if [ "$has_follow_up" -gt 0 ]; then
  _fail "manifest already has follow_up entries — refusing to re-file. Delete the manifest and re-run review-and-fix to regenerate." 2
fi

# ════════════════════════════════════════════════════════════════════════════════
# Main filing logic
# ════════════════════════════════════════════════════════════════════════════════
if [ "$dry_run" -eq 1 ]; then
  filed_by="(dry-run-user)"
else
  filed_by="$(_gh_login)"
fi
filed_at="$(_now_iso)"

# Build ordered list of unique files (preserving first-seen order)
# jq: extract file fields in order, deduplicate preserving first-seen
unique_files="$(printf '%s' "$manifest_json" | jq -r '
  .deferrals | reduce .[] as $d (
    {"seen": {}, "order": []};
    if (.seen[$d.file // "(unknown)"] // false | not) then
      .seen[$d.file // "(unknown)"] = true |
      .order += [$d.file // "(unknown)"]
    else . end
  ) | .order[]
')"

succeeded_numbers=""
failed_files=""
surviving_json="[]"

while IFS= read -r file_path; do
  [ -n "$file_path" ] || continue

  # Get all findings for this file (in original array order)
  findings_for_file="$(printf '%s' "$manifest_json" | \
    jq --arg fp "$file_path" '[.deferrals[] | select((.file // "(unknown)") == $fp)]')"

  area="$(_derive_area "$file_path")"
  title="$(_issue_title "$area" "$file_path" "$source_issue")"
  body="$(_render_issue_body "$findings_for_file" "$source_issue" "$pr_number")"

  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] would file issue: %s\n' "$title" >&2
    preview="${body:0:300}"
    printf '[dry-run] body preview (%d chars):\n%s%s\n' \
      "${#body}" "$preview" "$([ ${#body} -gt 300 ] && printf '…' || true)" >&2
    issue_number=0
    issue_url="https://example.invalid/dry-run"
  else
    # File real issue via gh
    local_url=""
    if ! local_url="$(printf '%s' "$body" | \
        gh issue create --title "$title" --body-file - 2>/tmp/_dfr_issue_err)"; then
      local_err="$(cat /tmp/_dfr_issue_err 2>/dev/null || true)"
      rm -f /tmp/_dfr_issue_err
      printf 'file-deferrals.sh: failed to file issue for %s: %s\n' \
        "$file_path" "$local_err" >&2
      failed_files="${failed_files}${file_path} "
      continue
    fi
    rm -f /tmp/_dfr_issue_err
    # Parse issue URL from last line of gh output
    issue_url="$(printf '%s' "$local_url" | tail -1 | sed 's/[[:space:]]//g')"
    if printf '%s' "$issue_url" | grep -qF '/issues/'; then
      issue_number="$(printf '%s' "$issue_url" | awk -F'/' '{print $NF}')"
    else
      printf 'file-deferrals.sh: unexpected gh output for %s: %s\n' \
        "$file_path" "$local_url" >&2
      failed_files="${failed_files}${file_path} "
      continue
    fi
  fi

  # Add follow_up to each finding and accumulate surviving entries
  follow_up_json="$(jq -n \
    --argjson num "$issue_number" \
    --arg url "$issue_url" \
    --arg at "$filed_at" \
    --arg by "$filed_by" \
    '{"issue": $num, "url": $url, "filed_at": $at, "filed_by": $by}')"

  # Build updated findings with id and follow_up
  updated_findings="$(printf '%s' "$findings_for_file" | jq \
    --arg prefix "" \
    --argjson follow_up "$follow_up_json" \
    '[.[] | . + {
      "id": ("dfr-" + (
        ((.file // "") + "|" + (.symbol // "") + "|" + (.kind // "") + "|" + ((.summary // "") | ltrimstr(" ") | rtrimstr(" ")))
        | @base64d
      ))
    }]' 2>/dev/null || printf '%s' "$findings_for_file")"

  # Since jq cannot do sha256, we need to compute IDs per-entry using shell
  # Build updated findings JSON by processing each entry
  local_count="$(printf '%s' "$findings_for_file" | jq 'length')"
  updated_findings="[]"
  local_i=0
  while [ "$local_i" -lt "$local_count" ]; do
    local_entry="$(printf '%s' "$findings_for_file" | jq ".[$local_i]")"
    local_file="$(printf '%s' "$local_entry" | jq -r '.file // ""')"
    local_sym="$(printf '%s' "$local_entry" | jq -r '.symbol // ""')"
    local_kind="$(printf '%s' "$local_entry" | jq -r '.kind // ""')"
    local_summary="$(printf '%s' "$local_entry" | jq -r '.summary // ""')"
    local_id="$(_compute_id "$local_file" "$local_sym" "$local_kind" "$local_summary")"

    local_updated="$(printf '%s' "$local_entry" | jq \
      --arg id "$local_id" \
      --argjson follow_up "$follow_up_json" \
      '. + {"id": $id, "follow_up": $follow_up}')"

    updated_findings="$(printf '%s\n%s' "$updated_findings" "$local_updated" | jq -s \
      'if length == 2 then .[0] + [.[1]] else . end')"
    local_i=$((local_i + 1))
  done

  surviving_json="$(printf '%s\n%s' "$surviving_json" "$updated_findings" | jq -s '.[0] + .[1]')"
  succeeded_numbers="${succeeded_numbers}${issue_number}"$'\n'
done <<EOF
$unique_files
EOF

# ════════════════════════════════════════════════════════════════════════════════
# Check if anything survived
# ════════════════════════════════════════════════════════════════════════════════
surviving_count="$(printf '%s' "$surviving_json" | jq 'length')"
if [ "$surviving_count" -eq 0 ]; then
  _fail "no follow-up issues filed — every group failed" 1
fi

# ════════════════════════════════════════════════════════════════════════════════
# Rewrite manifest (or dry-run summary)
# ════════════════════════════════════════════════════════════════════════════════
generated_at="$(printf '%s' "$manifest_json" | jq -r '.generated_at // ""')"
[ -n "$generated_at" ] || generated_at="$filed_at"

new_manifest="$(printf '%s' "$manifest_json" | jq \
  --argjson deferrals "$surviving_json" \
  --arg generated_at "$generated_at" \
  --arg filed_at "$filed_at" \
  '. + {"deferrals": $deferrals, "generated_at": $generated_at, "filed_at": $filed_at}')"

if [ "$dry_run" -eq 1 ]; then
  failed_count=0
  [ -n "$failed_files" ] && failed_count="$(printf '%s' "$failed_files" | wc -w)"
  printf '[dry-run] would rewrite manifest with %d entries, dropping %d failed group(s)\n' \
    "$surviving_count" "$failed_count" >&2
else
  _write_manifest_atomic "$manifest_path" "$new_manifest"
fi

# Print succeeded issue numbers (one per line)
printf '%s' "$succeeded_numbers"

# Report failed files if any
if [ -n "$failed_files" ]; then
  failed_count="$(printf '%s' "$failed_files" | wc -w)"
  printf 'file-deferrals.sh: %d group(s) failed and were dropped from manifest: %s\n' \
    "$failed_count" "$failed_files" >&2
fi

exit 0
