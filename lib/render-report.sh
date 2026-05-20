#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# render-report.sh — sourceable; defines devflow_render_report <summary-json>
# Prints a markdown run-report to stdout. Pure function — no gh/git calls.
set -euo pipefail

devflow_render_report() {
    local summary_json="$1"

    # Guard against malformed summary JSON before attempting any field extraction.
    jq empty <<<"$summary_json" \
      || { echo "::error::render-report: summary JSON is malformed" >&2; return 1; }

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local prs_scanned clean_count analyzed_count
    prs_scanned="$(echo "$summary_json" | jq -r '.prs_scanned // 0')"
    clean_count="$(echo "$summary_json" | jq -r '.clean_count // 0')"
    analyzed_count="$(echo "$summary_json" | jq -r '.analyzed_count // 0')"

    printf '<!-- devflow:audit-report -->\n'
    printf '# DevFlow Weekly Report\n\n'
    printf '**Run finished:** %s\n\n' "$ts"

    printf '## Summary\n\n'
    printf 'PRs scanned: %s\n' "$prs_scanned"
    printf 'clean (no analysis): %s\n' "$clean_count"
    printf 'analyzed: %s\n' "$analyzed_count"

    # Analyzed PRs — one line each (omitted when the caller did not pass `analyzed`)
    local analyzed_n
    analyzed_n="$(echo "$summary_json" | jq -r '(.analyzed // []) | length')"
    if [ "$analyzed_n" -gt 0 ]; then
        printf '\n### Analyzed PRs\n\n'
        echo "$summary_json" | jq -r '
            (.analyzed // [])[]
            | "- #\(.pr) — \(.verdict): " +
              ((.summary // "") | gsub("\n";" ") | if length > 220 then .[0:217] + "…" else . end)'
    fi

    # Patterns — full picture: acted-on / cooldown / dismissed / below-threshold
    # (omitted when the caller did not pass `patterns`)
    local patterns_n
    patterns_n="$(echo "$summary_json" | jq -r '(.patterns // []) | length')"
    if [ "$patterns_n" -gt 0 ]; then
        printf '\n## Patterns this run\n\n'
        echo "$summary_json" | jq -r '
            (.patterns // [])
            | sort_by(-(.occurrence_count // 0))[]
            | "- `\(.tag // .slug)` — \(.occurrence_count // 0)× (status: \(.status // "open"))"
              + (if (.cooldown_active // false) then " — cooldown, skipped this run" else "" end)'
    fi

    # Intervention PRs
    printf '\n## Intervention PRs\n\n'
    local intervention_count
    intervention_count="$(echo "$summary_json" | jq -r '(.intervention_prs // []) | length')"
    if [ "$intervention_count" -eq 0 ]; then
        printf '_None opened._\n'
    else
        echo "$summary_json" | jq -r '(.intervention_prs // [])[] | "- PR #\(.number) — `\(.tag)`"'
    fi

    # Meta-issues filed (omit section if empty)
    local meta_count
    meta_count="$(echo "$summary_json" | jq -r '(.meta_issues // []) | length')"
    if [ "$meta_count" -gt 0 ]; then
        printf '\n## Meta-issues filed\n\n'
        echo "$summary_json" | jq -r '(.meta_issues // [])[] | "- `\(.tag)` — \(.url)"'
    fi

    # Cooldown-skipped patterns (omit section if empty)
    local cooldown_count
    cooldown_count="$(echo "$summary_json" | jq -r '(.cooldown_skipped // []) | length')"
    if [ "$cooldown_count" -gt 0 ]; then
        printf '\n## Cooldown-skipped patterns\n\n'
        echo "$summary_json" | jq -r '(.cooldown_skipped // [])[] | "- `\(.)`"'
    fi

    # Blockers (omit section if empty)
    local blocker_count
    blocker_count="$(echo "$summary_json" | jq -r '(.blockers // []) | length')"
    if [ "$blocker_count" -gt 0 ]; then
        printf '\n## Blockers\n\n'
        echo "$summary_json" | jq -r '(.blockers // [])[] | "- \(.)"'
    fi
}
