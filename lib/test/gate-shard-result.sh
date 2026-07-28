#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Aggregator gate for the concurrent CI job matrix (issue #877).
#
# The required merge-gate check `lib + python tests` is the aggregator job, which
# runs with `if: always()` so it still reports when a shard fails, cancels, or is
# skipped. That makes the shard-matrix result gate the branch-protection contract:
# without it the required check would go green over a matrix that never ran, which
# is the classic un-gating trap.
#
# This lives in a script rather than inline in ci.yml so the suite can DRIVE each
# arm (CLAUDE.md: inline workflow shell that selects a branch or composes a
# user-facing message is extracted into a helper — a grep-pin on a message literal
# is not coverage of the selection that chooses it).
#
# Usage: bash lib/test/gate-shard-result.sh "<needs.shard.result>"
# Exit 0 only for the literal `success`; every other value, and an absent one,
# exits 1 with a GitHub `::error::` annotation naming the observed result.

set -u

result="${1-}"

printf 'shard matrix result: %s\n' "$result"

# Fail closed on an UNESTABLISHED result. An empty value means the expression that
# should have carried the matrix outcome resolved to nothing (a renamed job, a
# dropped `needs:` edge); treating that as anything but a failure would pass the
# required check over an outcome nobody observed — unknown is not success.
if [ -z "$result" ]; then
  printf '::error::the shard matrix result was not supplied — refusing to pass the required check over an unestablished shard outcome\n'
  exit 1
fi

if [ "$result" != "success" ]; then
  printf '::error::one or more test shards did not succeed (%s)\n' "$result"
  exit 1
fi

exit 0
