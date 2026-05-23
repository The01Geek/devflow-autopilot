#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Compute the canonical feature-branch name for a GitHub issue.
# Usage:
#   branch-for-issue.sh NUMBER TITLE
#   branch-for-issue.sh NUMBER --title-file PATH
#
# Exits 0 with the branch name on stdout.
# Exits 2 on bad arguments.
#
# Design notes:
#   - Unicode → ASCII: iconv -f UTF-8 -t ASCII//TRANSLIT. For ASCII and common
#     accented Latin (é→e, ñ→n, ü→u) this matches Python's old NFKD+ascii-ignore.
#     For exotic symbols (e.g. ½, ×, →, ℃) iconv//TRANSLIT and NFKD diverge — the
#     resulting slug is still deterministic and a valid branch name, just not
#     byte-identical to the old python. That is acceptable: a branch slug is
#     cosmetic + collision-handled (date suffix), not a stable key.
#   - Slug truncation at 50 chars, preferring a hyphen boundary if the
#     head is > 20 chars; matches Python _slugify() exactly.
#   - Date suffix uses `date +%Y%m%d` (LOCAL time), matching Python's
#     date.today() which also returns local date — NOT UTC.
#   - --title-file reading strips leading/trailing whitespace (matching
#     Python's f.read().strip()).
set -euo pipefail

MAX=50
MIN_HEAD=20

number="${1:-}"
shift || true

if [ -z "${number}" ] || ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "branch-for-issue.sh: NUMBER required (positive integer)" >&2
  exit 2
fi

# Parse title source: positional TITLE or --title-file PATH (exactly one).
# Python errors when both or neither is given; we reject extra args to match.
if [ "${1:-}" = "--title-file" ]; then
  if [ -z "${2:-}" ]; then
    echo "branch-for-issue.sh: --title-file needs PATH" >&2
    exit 2
  fi
  if [ "$#" -gt 2 ]; then
    echo "branch-for-issue.sh: provide exactly one of TITLE or --title-file" >&2
    exit 2
  fi
  # Python does f.read().strip() — strip leading/trailing whitespace and newlines.
  title="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "$2")"
elif [ -n "${1:-}" ]; then
  if [ "$#" -gt 1 ]; then
    echo "branch-for-issue.sh: provide exactly one of TITLE or --title-file" >&2
    exit 2
  fi
  title="${1}"
else
  echo "branch-for-issue.sh: provide TITLE (positional) or --title-file PATH" >&2
  exit 2
fi

# Unicode → ASCII transliteration. iconv //TRANSLIT maps accented chars
# (é → e, Ñ → N). Two separate substitutions (not a pipe-after-||) so a partial
# iconv write on invalid UTF-8 can't concatenate with the fallback's output.
if ! ascii="$(printf '%s' "$title" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)"; then
  ascii="$(printf '%s' "$title" | LC_ALL=C tr -cd '\11\12\15\40-\176')"
fi

# Build slug: lowercase, replace runs of non-[a-z0-9] with '-', strip ends.
slug="$(printf '%s' "$ascii" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

# Truncate slug to MAX (50) chars, preferring a hyphen boundary when the
# resulting head is longer than MIN_HEAD (20) — matching Python _slugify().
if [ "${#slug}" -gt "$MAX" ]; then
  cut="${slug:0:$MAX}"
  head="${cut%-*}"   # remove shortest suffix starting with '-' = rfind('-')
  if [ "${#head}" -gt "$MIN_HEAD" ] && [ "$head" != "$cut" ]; then
    cut="$head"
  fi
  slug="$(printf '%s' "$cut" | sed -E 's/^-+//; s/-+$//')"
fi

# Assemble base branch name.
if [ -z "$slug" ]; then
  base="issue-${number}"
else
  base="issue-${number}-${slug}"
fi

# Append today's date if branch already exists locally or on origin.
branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1" 2>/dev/null && return 0
  git show-ref --verify --quiet "refs/remotes/origin/$1" 2>/dev/null && return 0
  return 1
}

if branch_exists "$base"; then
  base="${base}-$(date +%Y%m%d)"
fi

printf '%s\n' "$base"
