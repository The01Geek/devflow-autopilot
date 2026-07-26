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

    local skipped_count
    skipped_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '.skipped_count // 0')"

    printf '## Summary\n\n'
    printf 'PRs scanned: %s\n' "$prs_scanned"
    printf 'clean (no analysis): %s\n' "$clean_count"
    printf 'analyzed: %s\n' "$analyzed_count"
    printf 'skipped: %s\n' "$skipped_count"

    # Skips (issue #626) — every skip class writes a one-line record so no skip is
    # ever silent: the mechanical no-provenance pre-dispatch skip, the Stage A
    # Cancelled skip, and the Stage A interim skip. Omitted when nothing was skipped.
    local skips_n
    # `|| true` + numeric guard, mirroring open-state-pr.sh's identical jq-count
    # fallback. `length` aborts jq on a boolean `.skips` (a hand-corrupted summary),
    # and under `set -e` a bare failing substitution would kill the whole report —
    # losing every other section over one malformed optional key. Tolerate the abort,
    # then degrade a non-numeric result to 0 so the section is merely omitted.
    skips_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.skips // []) | length' 2>/dev/null || true)"
    case "$skips_n" in ''|*[!0-9]*) skips_n=0 ;; esac
    if [ "$skips_n" -gt 0 ]; then
        printf '\n### Skipped PRs (mechanical no-provenance / Cancelled / interim)\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.skips // [])[] | "- " + (. | gsub("\n";" "))'
    fi

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

    # Patterns this run — the array the orchestrator passes in `.patterns` is the
    # actionable view (lib/actionable-patterns.sh output): open/regressed patterns
    # at or above min_occurrences, each with its lifecycle status and cooldown flag.
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

    # Withheld by a filing cap (issue #788) — every pattern the back-pressure caps
    # kept from being filed this run, named together with the cap that withheld it.
    # (omitted when nothing was withheld)
    local withheld_n
    withheld_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.withheld // []) | length' 2>/dev/null || true)"
    case "$withheld_n" in ''|*[!0-9]*) withheld_n=0 ;; esac
    if [ "$withheld_n" -gt 0 ]; then
        printf '\n## Withheld by a filing cap\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.withheld // [])[] | "- `\(.tag // .slug)` — withheld by `\(.cap)`"'
    fi

    # Re-filed after a won't-fix (issue #788) — a pattern whose meta-issue was
    # previously closed NOT_PLANNED but which keeps recurring is re-raised, not
    # silently permanent; the maintainer is told, and told the one durable off-switch.
    local refiled_n
    refiled_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.refiled_declined // []) | length' 2>/dev/null || true)"
    case "$refiled_n" in ''|*[!0-9]*) refiled_n=0 ;; esac
    if [ "$refiled_n" -gt 0 ]; then
        printf '\n## Re-filed after a won'"'"'t-fix\n\n'
        printf 'These patterns were re-filed this run after their meta-issue was closed `NOT_PLANNED`. To stop one permanently, add a `dismissed{}` entry to `.devflow/learnings/overrides.json` by hand — no machine path writes that map.\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.refiled_declined // [])[] | "- `\(.tag // .slug)`"'
    fi

    # Liveness warning (issue #788) — the eligible set is empty while a pattern at or
    # above the threshold sits suppressed (dismissed/declined/fixed). (omitted when absent)
    local liveness
    liveness="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '.liveness_warning // ""' 2>/dev/null || true)"
    if [ -n "$liveness" ]; then
        printf '\n## ⚠️ Liveness\n\n'
        printf -- '- %s\n' "$liveness"
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
        # recurring-targets.jq already emits this order; the sort mirrors its
        # canonical key so render-report stays self-contained (like the patterns
        # section) and never depends on the caller pre-sorting the array.
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
