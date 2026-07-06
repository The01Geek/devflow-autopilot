#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Shared, markdown-aware detector for a STANDALONE light /devflow:* command
# (/devflow:review, /devflow:review-and-fix, /devflow:pr-description).
#
# A command is "standalone" only when it is the sole content of its own line:
#   - it begins the line with at most three leading spaces (never a tab, never
#     four-plus spaces — so an *indented* code block never qualifies),
#   - it is NOT inside a fenced (``` or ~~~) code block, and
#   - the remainder of the line is at most an optional #-prefixed issue/PR
#     number plus trailing whitespace.
# A command merely *quoted in prose* (`please run /devflow:review`), in a `>`
# blockquote, indented as code, or inside a fenced block does NOT qualify. This
# is the single implementation of the anchored line scan.
# scripts/resolve-command-trigger.sh (the authoritative trigger gate) routes
# through it today; the review_dedupe job in .github/workflows/devflow.yml is
# INTENDED to route through it too (so the two matchers cannot drift), but that
# workflow change is a deferred, workflows-scoped follow-up (see
# docs/workflow-triggers.md) — until it lands, review_dedupe keeps its own
# coarse `case`-substring match.
#
# Detection is deliberately FAIL-CLOSED on an unbalanced fence: after an
# unclosed opening fence every following line is treated as code and fires
# nothing — matching how GitHub itself renders an unbalanced fence, and the safe
# direction for a self-trigger fix (over-exclude rather than over-fire).
#
# Most-specific-first: /devflow:review-and-fix outranks /devflow:review (the
# anchored own-line match already disambiguates — the review pattern requires
# the line to end right after `review`, which `review-and-fix` violates — but
# the ordering is kept explicit as belt-and-suspenders).
#
# The scanner approximates GitHub-flavored markdown; it is not a full CommonMark
# parser. It recognizes fenced blocks and 4-space / tab indented blocks, but
# does not model list-relative indentation, so a command deeply indented inside
# a list item is treated as code and does not fire (over-exclusion, the safe
# direction).
#
# Input: the comment/review body on STDIN.
# Output (stdout), always both lines:
#   command=/devflow:<cmd>|""   the matched canonical command token, or empty
#   number=<n>|""               the explicit number on the matched line, or empty
# Matching is case-insensitive (mirrors the pre-anchoring grep -i behavior);
# the emitted command token is always canonical lowercase.
#
# Uses POSIX awk + ERE only (no grep -P / GNU-only flags), per the resolver
# family's portability convention.
set -euo pipefail

awk '
BEGIN { infence = 0; fencechar = ""; found = 0; cmd = ""; num = "" }
found == 0 {
  line = $0
  # Strip a trailing carriage return so a CRLF body (GitHub delivers comment /
  # review bodies with \r\n line endings) matches the end-anchored patterns
  # below; without this every standalone command on a CRLF line silently
  # declines. Done first so the fence/indent tests and number extraction all see
  # the clean line.
  sub(/\r$/, "", line)
  # Fence toggle: an opening/closing ``` or ~~~ with at most three leading
  # spaces (an info string like ```bash is tolerated on the opener). Per
  # GitHub-flavored markdown a fence is closed only by the SAME marker type, so
  # track the opening char and ignore the other type while inside a fence (a
  # ~~~ line inside a ``` block is literal content, not a close). The fence line
  # itself is never a command line.
  if (line ~ /^ {0,3}(```|~~~)/) {
    if (infence == 0) {
      infence = 1
      fencechar = (line ~ /^ {0,3}~~~/) ? "~" : "`"
    } else if ((fencechar == "~" && line ~ /^ {0,3}~~~/) || (fencechar == "`" && line ~ /^ {0,3}```/)) {
      infence = 0; fencechar = ""
    }
    next
  }
  if (infence) next
  # Indented code block: a leading tab, or four-plus leading spaces.
  if (line ~ /^\t/ || line ~ /^ {4,}/) next
  # Anchored own-line match, case-insensitive, most-specific-first.
  low = tolower(line)
  if (low ~ /^ {0,3}\/devflow:review-and-fix([ \t]+#?[0-9]+)?[ \t]*$/) { cmd = "/devflow:review-and-fix" }
  else if (low ~ /^ {0,3}\/devflow:review([ \t]+#?[0-9]+)?[ \t]*$/) { cmd = "/devflow:review" }
  else if (low ~ /^ {0,3}\/devflow:pr-description([ \t]+#?[0-9]+)?[ \t]*$/) { cmd = "/devflow:pr-description" }
  else next
  # Extract an explicit number from the matched line, if present. The line is
  # anchored to hold only the command + optional number, so the first digit run
  # (stripped of a leading #) is that number.
  if (match(line, /#?[0-9]+/)) { num = substr(line, RSTART, RLENGTH); sub(/^#/, "", num) }
  found = 1
}
END {
  printf "command=%s\n", cmd
  printf "number=%s\n", num
}
'
