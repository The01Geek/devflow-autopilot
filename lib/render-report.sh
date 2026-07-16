#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# render-report.sh — sourceable; defines devflow_render_report <summary-json>
# Prints a markdown run-report to stdout. Pure function — no gh/git calls.
set -euo pipefail

# jq binary: resolved once via the sourced sibling resolver (issue #247);
# best-effort — a copied/vendored deployment without lib/ falls back to bare
# `jq` with a breadcrumb rather than aborting under set -e.
# shellcheck source=resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

devflow_render_report() {
    local summary_json="$1"

    # Guard against malformed summary JSON before attempting any field extraction.
    "$DEVFLOW_JQ" empty <<<"$summary_json" \
      || { echo "::error::render-report: summary JSON is malformed" >&2; return 1; }

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local prs_scanned clean_count analyzed_count
    prs_scanned="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '.prs_scanned // 0')"
    clean_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '.clean_count // 0')"
    analyzed_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '.analyzed_count // 0')"

    printf '<!-- devflow:audit-report -->\n'
    printf '# DevFlow Weekly Report\n\n'
    printf '**Run finished:** %s\n\n' "$ts"

    printf '## Summary\n\n'
    printf 'PRs scanned: %s\n' "$prs_scanned"
    printf 'clean (no analysis): %s\n' "$clean_count"
    printf 'analyzed: %s\n' "$analyzed_count"

    # Analyzed PRs — one line each (omitted when the caller did not pass `analyzed`)
    local analyzed_n
    analyzed_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.analyzed // []) | length')"
    if [ "$analyzed_n" -gt 0 ]; then
        printf '\n### Analyzed PRs\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '
            (.analyzed // [])[]
            | "- #\(.pr) — \(.verdict): " +
              ((.summary // "") | gsub("\n";" ") | if length > 220 then .[0:217] + "…" else . end)'
    fi

    # Patterns — full picture: acted-on / cooldown / dismissed / below-threshold
    # (omitted when the caller did not pass `patterns`)
    local patterns_n
    patterns_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.patterns // []) | length')"
    if [ "$patterns_n" -gt 0 ]; then
        printf '\n## Patterns this run\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '
            (.patterns // [])
            | sort_by(-(.occurrence_count // 0))[]
            | "- `\(.tag // .slug)` — \(.occurrence_count // 0)× (status: \(.status // "open"))"
              + (if (.cooldown_active // false) then " — cooldown, skipped this run" else "" end)'
    fi

    # Recurring intervention targets (issue #520) — report-only: the files/areas
    # the accumulated retrospectives.jsonl repeatedly points at, ranked by
    # distinct-PR count. Files no issue and writes no dismissal state, so it
    # surfaces recurring targets regardless of overrides.json dismissal. Omitted
    # when no target reaches >= 2 distinct PRs (the helper emits [] then), mirroring
    # the optional-section idiom above.
    local recurring_n
    recurring_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.recurring_targets // []) | length')"
    if [ "$recurring_n" -gt 0 ]; then
        printf '\n## Recurring intervention targets\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '
            (.recurring_targets // [])
            | sort_by([-(.pr_count // 0), .target])[]
            | "- `\(.target)` — \(.pr_count // 0) PRs (\((.prs // []) | map("#\(.)") | join(", "))): "
              + ((.representative_summary // "") | gsub("\n";" ") | if length > 220 then .[0:217] + "…" else . end)'
    fi

    # Issues filed — one per actionable pattern (the loop proposes, not disposes:
    # each pattern becomes a GitHub issue for the normal implement -> review pipeline)
    printf '\n## Issues filed\n\n'
    local issues_count
    issues_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.intervention_issues // []) | length')"
    if [ "$issues_count" -eq 0 ]; then
        printf '_None filed._\n'
    else
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.intervention_issues // [])[] | "- `\(.tag)` — \(.url)"'
    fi

    # Cooldown-skipped patterns (omit section if empty)
    local cooldown_count
    cooldown_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.cooldown_skipped // []) | length')"
    if [ "$cooldown_count" -gt 0 ]; then
        printf '\n## Cooldown-skipped patterns\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.cooldown_skipped // [])[] | "- `\(.)`"'
    fi

    # Blockers (omit section if empty)
    local blocker_count
    blocker_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.blockers // []) | length')"
    if [ "$blocker_count" -gt 0 ]; then
        printf '\n## Blockers\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.blockers // [])[] | "- \(.)"'
    fi
}
