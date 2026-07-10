#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-skip-title.sh — render the deferred 'Devflow Review' check-run TITLE for a
# given precheck skip reason (issue #389).
#
# Why a helper rather than an inline `case` in devflow-review.yml (issue #389, mirroring
# describe-denial-count.sh / PR #367): this title IS the user-facing account of WHY the
# review was deferred, so a silently mis-selected arm (a reordered `case`, a glob typo)
# would misattribute the deferral while the workflow still ran clean. Inline shell inside
# YAML cannot be unit-tested; here lib/test/run.sh drives every arm AND its order.
#
# Honesty rule (load-bearing — carried verbatim from the extraction site): the title must
# never assert a state the precheck did not observe. behind-base / ci-not-green /
# ci-approval-required are POSITIVELY-OBSERVED conditions; `unverifiable` means a
# precondition query failed (so the title names the query failure, not a concrete cause);
# the `*` default is the deliberately generic "precondition not met", which asserts no
# specific cause. A user who rebases in response to a false "branch behind base" fixes
# nothing — so an unobserved cause is never named.
#
# Usage: describe-skip-title.sh [SKIP_REASON]
#   SKIP_REASON  a precheck skip-reason token (see the arms below). A recognized token
#                maps to its title; any other value (incl. empty) -> the generic default.
# Prints one title to stdout. Always exits 0.

set -u

case "${1:-}" in
  behind-base)          printf '%s\n' 'Devflow review waiting: branch behind base' ;;
  ci-not-green)         printf '%s\n' 'Devflow review waiting: other CI not green' ;;
  ci-approval-required) printf '%s\n' 'Devflow review waiting: CI approval required' ;;
  unverifiable)         printf '%s\n' 'Devflow review waiting: preconditions unverifiable (API query failed — see the precheck log)' ;;
  *)                    printf '%s\n' 'Devflow review waiting: precondition not met' ;;
esac
exit 0
