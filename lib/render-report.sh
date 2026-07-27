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
    # Guarded for the reason `skips_n` documents above: `// []` does not replace
    # a truthy non-array key, so an unguarded `length` would abort jq and, under
    # `set -e`, take the WHOLE report down over one malformed key.
    analyzed_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.analyzed // []) | length' 2>/dev/null || true)"
    case "$analyzed_n" in ''|*[!0-9]*) analyzed_n=0 ;; esac
    if [ "$analyzed_n" -gt 0 ]; then
        printf '\n### Analyzed PRs\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '
            (.analyzed // [])[]
            | "- #\(.pr) — \(.verdict): " +
              ((.summary // "") | gsub("\n";" ") | if length > 220 then .[0:217] + "…" else . end)'
    fi

    # Patterns — the UNFILTERED view (issue #788): the orchestrator passes the whole
    # pattern picture (every lifecycle state — filed/fixed/declined/regressed/open,
    # plus dismissed and below-threshold), each carrying its filing outcome for this
    # run and, where it was withheld, the cap that withheld it. Omitted when the
    # caller did not pass `patterns`.
    local patterns_n
    # Guarded for the reason `skips_n` documents above: `// []` does not replace
    # a truthy non-array key, so an unguarded `length` would abort jq and, under
    # `set -e`, take the WHOLE report down over one malformed key.
    patterns_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.patterns // []) | length' 2>/dev/null || true)"
    # Unlike the optional sections, degrading THIS key to 0 must not be silent.
    # `.patterns` is the report's substance, and the upstream producer
    # (`devflow_annotate_patterns`) fails loud precisely so a producer failure
    # cannot render as a quiet week — but its protection is the caller's
    # `: "${PATTERNS_JSON:?…}"`, which tests for the EMPTY STRING and therefore
    # cannot see a non-empty malformed value that reaches this renderer. Without
    # a breadcrumb here, a truthy non-array `.patterns` produces a complete,
    # plausible report with the pattern section simply absent — indistinguishable
    # from a week with no patterns. Say so.
    case "$patterns_n" in
        ''|*[!0-9]*)
            echo "::warning::render-report: the summary's \`patterns\` key is malformed (not an array) — the 'Patterns this run' section is OMITTED, which is NOT evidence that there were no patterns" >&2
            patterns_n=0 ;;
    esac
    if [ "$patterns_n" -gt 0 ]; then
        printf '\n## Patterns this run\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '
            (.patterns // [])
            | sort_by(-(.occurrence_count // 0))[]
            | "- `\(.tag // .slug)` — \(.occurrence_count // 0)× (status: \(.status // "open"))"
              + (if (.filing_outcome // "") != "" then " — \(.filing_outcome)" else "" end)
              + (if (.withheld_by // "") != "" then " — withheld by `\(.withheld_by)`" else "" end)
              + (if (.cooldown_active // false) then " — cooldown, skipped this run" else "" end)'
    fi

    # Liveness (issue #788) — when actionable-patterns.sh emitted a `liveness:` line
    # (no pattern eligible while a suppressed pattern has occurred at/above threshold), the
    # orchestrator carries it into the summary so the report surfaces the silent
    # exhaustion rather than reading like a genuinely quiet week.
    local liveness
    liveness="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '.liveness_warning // ""')"
    if [ -n "$liveness" ]; then
        printf '\n## Liveness warning\n\n'
        printf -- '- %s\n' "$liveness"
    fi

    # Withheld by a filing cap (issue #788) — every pattern the back-pressure caps
    # held back this run, named with the cap that withheld it.
    local withheld_n
    # Same `|| true` + numeric-degrade guard `skips_n` documents above: `// []`
    # does not replace a truthy non-array key, so a hand-corrupted
    # `withheld_patterns` would abort `length` and, under `set -e`, kill the whole
    # report over one malformed optional key.
    withheld_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.withheld_patterns // []) | length' 2>/dev/null || true)"
    case "$withheld_n" in ''|*[!0-9]*) withheld_n=0 ;; esac
    if [ "$withheld_n" -gt 0 ]; then
        printf '\n## Patterns withheld by a filing cap\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.withheld_patterns // [])[] | "- `\(.tag // .slug)` — withheld by `\(.cap)`"'
    fi

    # Won't-fix re-raised (issue #788) — patterns re-filed this run whose meta-issue
    # was previously closed NOT_PLANNED. The lifecycle deliberately re-raises a
    # recurring won't-fix; name each one and the one durable off-switch (a human
    # `dismissed{}` entry) so the maintainer's decision is re-raised visibly.
    local declined_refiled_n
    # Guarded for the reason `skips_n`/`withheld_n` document above.
    declined_refiled_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.declined_refiled // []) | length' 2>/dev/null || true)"
    case "$declined_refiled_n" in ''|*[!0-9]*) declined_refiled_n=0 ;; esac
    if [ "$declined_refiled_n" -gt 0 ]; then
        printf '\n## Won'"'"'t-fix patterns re-raised this run\n\n'
        printf 'These recurred after being closed not-planned. To stop one permanently, add a human `dismissed{}` entry to `.devflow/learnings/overrides.json`.\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.declined_refiled // [])[] | "- `\(.)`"'
    fi

    # Recurring intervention targets (issue #520) — report-only: the files/areas
    # the accumulated retrospectives.jsonl repeatedly points at, ranked by
    # distinct-PR count. Files no issue and writes no dismissal state, so it
    # surfaces recurring targets regardless of overrides.json dismissal. Omitted
    # when no target reaches >= 2 distinct PRs (the helper emits [] then), mirroring
    # the optional-section idiom above.
    local recurring_n
    # Guarded for the reason `skips_n` documents above: `// []` does not replace
    # a truthy non-array key, so an unguarded `length` would abort jq and, under
    # `set -e`, take the WHOLE report down over one malformed key.
    recurring_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.recurring_targets // []) | length' 2>/dev/null || true)"
    case "$recurring_n" in ''|*[!0-9]*) recurring_n=0 ;; esac
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
    issues_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.intervention_issues // []) | length' 2>/dev/null || true)"
    case "$issues_count" in ''|*[!0-9]*) issues_count=0 ;; esac
    if [ "$issues_count" -eq 0 ]; then
        printf '_None filed._\n'
    else
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.intervention_issues // [])[] | "- `\(.tag)` — \(.url)"'
    fi

    # Cooldown-skipped patterns (omit section if empty)
    local cooldown_count
    cooldown_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.cooldown_skipped // []) | length' 2>/dev/null || true)"
    case "$cooldown_count" in ''|*[!0-9]*) cooldown_count=0 ;; esac
    if [ "$cooldown_count" -gt 0 ]; then
        printf '\n## Cooldown-skipped patterns\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.cooldown_skipped // [])[] | "- `\(.)`"'
    fi

    # Blockers (omit section if empty)
    local blocker_count
    blocker_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r '(.blockers // []) | length' 2>/dev/null || true)"
    # Like `patterns` above, this one must not degrade silently: `.blockers` is the
    # section that REPORTS failures, and failures being suppressed by a failure is
    # the worst possible pairing.
    case "$blocker_count" in
        ''|*[!0-9]*)
            echo "::warning::render-report: the summary's \`blockers\` key is malformed (not an array) — the blockers section is OMITTED, which is NOT evidence that there were no blockers" >&2
            blocker_count=0 ;;
    esac
    if [ "$blocker_count" -gt 0 ]; then
        printf '\n## Blockers\n\n'
        echo "$summary_json" | "$DEVFLOW_JQ" -r '(.blockers // [])[] | "- \(.)"'
    fi
}
