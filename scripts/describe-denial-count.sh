#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-denial-count.sh — render the permission-denial clause of the no-verdict
# `::error::` annotation (issue #363).
#
# Why a helper rather than an inline `case` in devflow-review.yml: this clause IS the
# accurate-diagnosis output the whole change exists to produce, so a silently
# mis-selected arm (a reordered `case`, a glob typo) defeats the feature while the
# workflow still "works". Inline shell inside YAML cannot be unit-tested; here
# lib/test/run.sh drives every arm directly.
#
# The three states are deliberately distinct — collapsing "unknown" onto "0" is the
# fail-open this issue exists to end:
#
#   ""  | non-digits  the count could not be established -> denials NOT ruled out
#   0                 the harness genuinely refused nothing -> look elsewhere
#   N > 0             the harness refused N commands -> that is the cause
#
# Usage: describe-denial-count.sh [COUNT]
#   COUNT  a digit string, the literal `unavailable`, or empty.
# Prints one clause to stdout. Always exits 0.

set -u

case "${1:-}" in
  '' | *[!0-9]*)
    printf '%s\n' "The permission-denial count could not be established (execution diagnostics unavailable), so denials cannot be ruled out as the cause"
    ;;
  0)
    printf '%s\n' "The harness refused no commands, so the stall has some other cause"
    ;;
  *)
    printf '%s\n' "The harness refused $1 command(s) during execution"
    ;;
esac
exit 0
