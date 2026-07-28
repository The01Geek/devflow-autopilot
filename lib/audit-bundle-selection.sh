#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# audit-bundle-selection.sh — sourceable; the executable owner of the Stage B
# occurrence-bundle cap validation and the most-recent-N selection (issue #894).
#
# The retrospective loop's Step 8a used to fetch a context bundle for EVERY
# occurrence PR of every actionable pattern, unbounded — a cost proportional to
# each pattern's cumulative occurrence history, growing monotonically with the
# corpus. This helper bounds that fetch: the skill fence resolves
# `.devflow_retrospective.audit_bundle_cap` (via config-get.sh, with the default
# 10), passes the resolved value to `devflow_validate_audit_bundle_cap`, and then
# asks `devflow_select_audit_bundles` for the most-recent-N occurrence PRs.
#
# The validation and selection live here rather than inline in the SKILL.md fence
# for the same reason lib/filing-decisions.sh exists: a mis-shaped cap or a
# wrong-order selection decides which evidence Stage B sees, and CLAUDE.md's
# convention bars leaving a branch-selecting decision inline in a non-testable
# prose surface — "a feature the suite cannot catch defeated". The suite drives
# both functions directly.
#
# Config-read boundary: this helper reads NO config — the skill fence resolves the
# cap through config-get.sh and passes it in. The reason is position, not a blanket
# rule: it is sourced at Step 8a, UPSTREAM of the entire filing loop, so a
# `set -euo pipefail` leaked in from lib/config-source.sh would abort the run at
# any later benign non-zero. This mirrors lib/filing-decisions.sh, which reads no
# config either.
#
# This file is SOURCED into the caller's shell and therefore deliberately sets no
# shell options: a `set -euo pipefail` here would leak into the orchestrator that
# sources it, where a later benign non-zero would abort the whole retrospective
# run. Every function validates its own operands and returns a value.

# jq binary: resolved once via the sourced sibling resolver (issue #247);
# best-effort — a copied/vendored deployment without lib/ falls back to bare
# `jq` with a breadcrumb rather than aborting under set -e. Matches the siblings
# lib/render-report.sh and lib/filing-decisions.sh (a `lib/` helper resolves jq
# through this resolver and invokes "$DEVFLOW_JQ", never the agent-tier
# run-jq.sh wrapper, which would fork a process per call).
# shellcheck source=resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

# devflow_validate_audit_bundle_cap <coerced-config-value>
#
# Prints the validated positive-integer cap on stdout (exit 0), or fails CLOSED
# with a targeted `::error::` and a non-zero exit. The input is the string
# config-get.sh coerced from whatever JSON the key held; config-get.sh already
# resolves an absent file / absent key / JSON null / empty string / empty array to
# the default 10, so a well-formed config never reaches here empty.
#
# Boundary (matches the composed config-get.sh boundary the sibling filing caps
# exhibit, per shape):
#   - a positive integer                 -> printed and used as the cap
#   - an EMPTY value                      -> the read FAILED (malformed config or a
#                                            resolver failure) -> abort, naming both
#                                            reachable causes (they are not
#                                            distinguishable from the empty value)
#   - `0` or any negative value           -> abort naming the key (unlike the filing
#                                            caps where 0 is a real off-switch — a
#                                            bundle cap of zero would starve Stage B)
#   - boolean false/object/multi-array/
#     non-numeric string/boolean true/3.5 -> abort naming the key (the residual arm)
devflow_validate_audit_bundle_cap() {
    local cap="${1:-}"
    if [ -z "$cap" ]; then
        echo "::error::audit-bundle-selection: the audit_bundle_cap read produced an empty value — this means either a malformed .devflow/config.json (its embedded python exits non-zero and config-get.sh's file-scope set -euo pipefail aborts the assignment before the default fallback) or a resolver failure (python3 absent, config-get.sh missing or non-executable). Refusing to launder either into a working cap of 10." >&2
        return 1
    fi
    # Any non-digit character reaches the residual arm: a boolean `false`/`true`, a
    # coerced object `[object Object]`, a comma-joined multi-element array, a
    # non-integer number `3.5`, a negative `-1`, or a non-numeric string.
    case "$cap" in
        *[!0-9]*)
            echo "::error::audit-bundle-selection: .devflow_retrospective.audit_bundle_cap must be a positive integer (got '$cap')" >&2
            return 1 ;;
    esac
    # All-digit now (0, 00, or positive). Reject zero and — via the same guard — a
    # value that is only zeros.
    if [ "$cap" -le 0 ]; then
        echo "::error::audit-bundle-selection: .devflow_retrospective.audit_bundle_cap must be a positive integer, not zero — a bundle cap of zero would starve Stage B of all evidence (got '$cap')" >&2
        return 1
    fi
    printf '%s\n' "$cap"
}

# devflow_select_audit_bundles <cap> <pattern-json>
#
# Prints, one per line, the `.pr` of the MOST-RECENT <cap> occurrences of the
# pattern, in DESCENDING occurrence-timestamp order. lib/compute-patterns.jq emits
# `occurrences` through `sort_by(.ts)` (ASCENDING), so the selection is the tail of
# that array reversed to descending `ts`. Emitting the order — not just the set —
# is load-bearing: Step 8a fetches in this order and the dispatch prompt states it
# to the Stage B subagent as fact.
#
# When the pattern has <= cap occurrences, every occurrence is selected (still
# reversed to descending ts). An absent/empty occurrences array selects nothing.
# <cap> is assumed pre-validated (a positive integer) by
# devflow_validate_audit_bundle_cap; it is passed as a jq number.
devflow_select_audit_bundles() {
    local cap="${1:-}" pattern="${2:-}"
    printf '%s' "$pattern" | "$DEVFLOW_JQ" -r --argjson cap "$cap" '
        (.occurrences // []) as $o
        | ($o | length) as $len
        | (if $cap >= $len then 0 else $len - $cap end) as $start
        | $o[$start:]
        | reverse
        | .[].pr'
}
