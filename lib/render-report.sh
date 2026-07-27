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

# _rr_emit <section-label> <jq-program>
# Render a section's rows from $summary_json, NAMING any jq failure instead of
# swallowing it. A blanket `|| true` on the element read turns an abort INSIDE a
# well-formed object element — a string `occurrence_count` aborting `sort_by`, a
# non-string `.summary` aborting `gsub` — into a silent empty section under a
# heading that has already printed. That is the same quiet-report-reads-as-quiet
# -week ambiguity the malformed-key guards exist to remove, one level down, and
# the key-level `::warning::` cannot fire for it because the key IS an array.
_rr_emit() {
    local label="$1" prog="$2" rows
    if rows="$(printf '%s' "$summary_json" | "$DEVFLOW_JQ" -r "$prog" 2>&1)"; then
        [ -z "$rows" ] || printf '%s\n' "$rows"
    else
        echo "::error::render-report: the ${label} rows could not be rendered (${rows}) — that section is INCOMPLETE, which is NOT evidence that it was empty" >&2
    fi
}

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
    # Count ONLY an actual array; every other shape emits nothing, which the
    # numeric case below degrades to 0 so the section is merely omitted.
    #
    # Why the type test and not a bare `length`: jq's `length` errors on a
    # BOOLEAN only. A string, a number and an object all return a count
    # (`"oops"|length` -> 4, `{"a":1}|length` -> 1, `5|length` -> 5), so a
    # `length`-plus-numeric-case guard waves those three shapes through as a
    # positive count. The section heading is then printed and the ELEMENT read
    # below is what aborts — truncating the report mid-render, after the heading,
    # and taking every later section with it under this file's `set -e`. The
    # element reads are separately made total (`map(select(type == "object"))`)
    # and non-aborting (`|| true`) for the same reason.
    skips_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.skips // [] | type) == "array" then (.skips // [] | length) else empty end' 2>/dev/null || true)"
    case "$skips_n" in ''|*[!0-9]*) skips_n=0 ;; esac
    if [ "$skips_n" -gt 0 ]; then
        printf '\n### Skipped PRs (mechanical no-provenance / Cancelled / interim)\n\n'
        _rr_emit skips '(.skips // [])[] | "- " + (. | tostring | gsub("\n";" "))'
    fi

    # Analyzed PRs — one line each (omitted when the caller did not pass `analyzed`)
    local analyzed_n
    # Type-tested for the reason `skips_n` documents above: `// []` does not
    # replace a truthy non-array key, and `length` counts a string/number/object
    # rather than erroring, so only an array is counted here and the element read
    # below is made total and non-aborting.
    analyzed_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.analyzed // [] | type) == "array" then (.analyzed // [] | map(select(type == "object")) | length) else empty end' 2>/dev/null || true)"
    case "$analyzed_n" in ''|*[!0-9]*) analyzed_n=0 ;; esac
    if [ "$analyzed_n" -gt 0 ]; then
        printf '\n### Analyzed PRs\n\n'
        _rr_emit analyzed '
            (.analyzed // [] | map(select(type == "object")))[]
            | "- #\(.pr // "?") — \(.verdict // "?"): " +
              (((.summary | strings) // "") | gsub("\n";" ") | if length > 220 then .[0:217] + "…" else . end)'
    fi

    # Patterns — the UNFILTERED view (issue #788): the orchestrator passes the whole
    # pattern picture (every lifecycle state — filed/fixed/declined/regressed/open,
    # plus dismissed and below-threshold), each carrying its filing outcome for this
    # run and, where it was withheld, the cap that withheld it. Omitted when the
    # caller did not pass `patterns`.
    local patterns_n
    # Type-tested for the reason `skips_n` documents above: `// []` does not
    # replace a truthy non-array key, and `length` counts a string/number/object
    # rather than erroring, so only an array is counted here and the element read
    # below is made total and non-aborting.
    patterns_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.patterns // [] | type) == "array" then (.patterns // [] | map(select(type == "object")) | length) else empty end' 2>/dev/null || true)"
    # Unlike the optional sections, degrading THIS key to 0 must not be silent.
    # `.patterns` is the report's substance, and the upstream producer
    # (`devflow_annotate_patterns`) fails loud precisely so a producer failure
    # cannot render as a quiet week — but its protection is the caller's
    # `: "${PATTERNS_JSON:?…}"`, which tests for the EMPTY STRING and therefore
    # cannot see a non-empty malformed value that reaches this renderer. Without
    # a breadcrumb here, a truthy non-array `.patterns` yields a report whose
    # pattern section is simply absent — indistinguishable from a week with no
    # patterns. Say so.
    case "$patterns_n" in
        ''|*[!0-9]*)
            echo "::warning::render-report: the summary's \`patterns\` key is malformed (not an array) — the 'Patterns this run' section is OMITTED, which is NOT evidence that there were no patterns" >&2
            patterns_n=0 ;;
    esac
    if [ "$patterns_n" -gt 0 ]; then
        printf '\n## Patterns this run\n\n'
        _rr_emit patterns '
            (.patterns // [] | map(select(type == "object")))
            | sort_by(-((.occurrence_count | numbers) // 0))[]
            | "- `\(.tag // .slug // "(unnamed)")` — \((.occurrence_count | numbers) // 0)× (status: \((.status | strings) // "open"))"
              + (if ((.filing_outcome | strings) // "") != "" then " — \(.filing_outcome)" else "" end)
              + (if ((.withheld_by | strings) // "") != "" then " — withheld by `\(.withheld_by)`" else "" end)
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
    # Same type-test + numeric-degrade guard `skips_n` documents above. The
    # element read is `map(select(type == "object"))`-filtered and `|| true`-ed
    # too: a well-formed array carrying ONE malformed element would otherwise
    # abort `.tag`/`.cap` after the heading was already printed.
    withheld_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.withheld_patterns // [] | type) == "array" then (.withheld_patterns // [] | map(select(type == "object")) | length) else empty end' 2>/dev/null || true)"
    case "$withheld_n" in ''|*[!0-9]*) withheld_n=0 ;; esac
    if [ "$withheld_n" -gt 0 ]; then
        printf '\n## Patterns withheld by a filing cap\n\n'
        _rr_emit withheld_patterns '(.withheld_patterns // [] | map(select(type == "object")))[] | "- `\(.tag // .slug // "(unnamed)")` — withheld by `\((.cap | strings) // "(unknown cap)")`"'
    fi

    # Won't-fix re-raised (issue #788) — patterns re-filed this run whose meta-issue
    # was previously closed NOT_PLANNED. The lifecycle deliberately re-raises a
    # recurring won't-fix; name each one and the one durable off-switch (a human
    # `dismissed{}` entry) so the maintainer's decision is re-raised visibly.
    local declined_refiled_n
    # Type-tested for the reason `skips_n`/`withheld_n` document above.
    declined_refiled_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.declined_refiled // [] | type) == "array" then (.declined_refiled // [] | length) else empty end' 2>/dev/null || true)"
    case "$declined_refiled_n" in ''|*[!0-9]*) declined_refiled_n=0 ;; esac
    if [ "$declined_refiled_n" -gt 0 ]; then
        printf '\n## Won'"'"'t-fix patterns re-raised this run\n\n'
        printf 'These recurred after being closed not-planned. To stop one permanently, add a human `dismissed{}` entry to `.devflow/learnings/overrides.json`.\n\n'
        _rr_emit declined_refiled '(.declined_refiled // [])[] | "- `\(. | tostring)`"'
    fi

    # Recurring intervention targets (issue #520) — report-only: the files/areas
    # the accumulated retrospectives.jsonl repeatedly points at, ranked by
    # distinct-PR count. Files no issue and writes no dismissal state, so it
    # surfaces recurring targets regardless of overrides.json dismissal. Omitted
    # when no target reaches >= 2 distinct PRs (the helper emits [] then), mirroring
    # the optional-section idiom above.
    local recurring_n
    # Type-tested for the reason `skips_n` documents above: `// []` does not
    # replace a truthy non-array key, and `length` counts a string/number/object
    # rather than erroring, so only an array is counted here and the element read
    # below is made total and non-aborting.
    recurring_n="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.recurring_targets // [] | type) == "array" then (.recurring_targets // [] | map(select(type == "object")) | length) else empty end' 2>/dev/null || true)"
    case "$recurring_n" in ''|*[!0-9]*) recurring_n=0 ;; esac
    if [ "$recurring_n" -gt 0 ]; then
        printf '\n## Recurring intervention targets\n\n'
        # recurring-targets.jq already emits this order; the sort mirrors its
        # canonical key so render-report stays self-contained (like the patterns
        # section) and never depends on the caller pre-sorting the array.
        _rr_emit recurring_targets '
            (.recurring_targets // [] | map(select(type == "object")))
            | sort_by([-((.pr_count | numbers) // 0), ((.target | strings) // "")])[]
            | "- `\(.target)` — \(.pr_count // 0) PRs (\((.prs // []) | map("#\(.)") | join(", "))): "
              + (((.representative_summary | strings) // "") | gsub("\n";" ") | if length > 220 then .[0:217] + "…" else . end)'
    fi

    # Issues filed — one per actionable pattern (the loop proposes, not disposes:
    # each pattern becomes a GitHub issue for the normal implement -> review pipeline)
    printf '\n## Issues filed\n\n'
    local issues_count
    issues_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.intervention_issues // [] | type) == "array" then (.intervention_issues // [] | map(select(type == "object")) | length) else empty end' 2>/dev/null || true)"
    # `_None filed._` is a POSITIVE assertion of fact, so it must never be printed
    # off an unestablished count. A malformed `intervention_issues` degraded to 0
    # would have the report affirmatively deny filings that did happen — strictly
    # worse than the ambiguous omitted-section case the other guards accept.
    case "$issues_count" in
        ''|*[!0-9]*)
            echo "::error::render-report: the summary's \`intervention_issues\` key is malformed (not an array) — refusing to print '_None filed._', which would be a false claim that nothing was filed" >&2
            printf '_Filing record unavailable — see the error above; this is NOT a claim that nothing was filed._\n'
            issues_count=-1 ;;
    esac
    if [ "$issues_count" -eq 0 ]; then
        printf '_None filed._\n'
    elif [ "$issues_count" -gt 0 ]; then
        _rr_emit intervention_issues '(.intervention_issues // [] | map(select(type == "object")))[] | "- `\(.tag // "(unnamed)")` — \(.url // "(no url)")"'
    fi

    # Cooldown-skipped patterns (omit section if empty)
    local cooldown_count
    cooldown_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.cooldown_skipped // [] | type) == "array" then (.cooldown_skipped // [] | length) else empty end' 2>/dev/null || true)"
    case "$cooldown_count" in ''|*[!0-9]*) cooldown_count=0 ;; esac
    if [ "$cooldown_count" -gt 0 ]; then
        printf '\n## Cooldown-skipped patterns\n\n'
        _rr_emit cooldown_skipped '(.cooldown_skipped // [])[] | "- `\(. | tostring)`"'
    fi

    # Blockers (omit section if empty)
    local blocker_count
    blocker_count="$(echo "$summary_json" | "$DEVFLOW_JQ" -r 'if (.blockers // [] | type) == "array" then (.blockers // [] | length) else empty end' 2>/dev/null || true)"
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
        _rr_emit blockers '(.blockers // [])[] | "- \(. | tostring)"'
    fi
}
