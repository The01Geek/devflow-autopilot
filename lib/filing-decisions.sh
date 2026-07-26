#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# filing-decisions.sh — sourceable; the executable owner of the retrospective
# loop's per-run filing decisions and of the report fields those decisions feed
# (issue #788).
#
# Every decision here used to live as prose in skills/retrospective-weekly's
# Step 8c/9, where a mis-ordered cap check or a lost regressed bypass would ship
# green. CLAUDE.md's convention is explicit that a branch-selecting decision left
# inline in a non-testable surface "is a feature the suite cannot catch
# defeated", so the decisions live here and the skill calls them.
#
# Defines:
#   devflow_filing_cap_verdict  — which cap (if any) withholds one pattern
#   devflow_liveness_warning    — the `liveness:` line actionable-patterns.sh
#                                 wrote to stderr, for the report's liveness line
#   devflow_declined_refiled    — the filed slugs whose meta-issue was previously
#                                 closed NOT_PLANNED (a re-raised won't-fix)
#   devflow_annotate_patterns   — per-pattern filing_outcome / withheld_by on the
#                                 unfiltered view the report renders
#   devflow_open_filed_total    — the max_open_issues comparand
#   devflow_open_filed_in_category — the max_open_per_category comparand
#
# Pure: no gh calls, no writes outside caller-supplied stdout.
#
# This file is SOURCED into a caller's shell and therefore deliberately sets no
# shell options: a `set -euo pipefail` here would leak into the orchestrator that
# sources it, where a later benign non-zero (a grep that matches nothing, an
# unset optional variable) would abort the whole retrospective run. Every
# function below is written to be safe without it — each validates its own
# operands and returns a value rather than relying on `-e` to stop the caller.

# jq binary: resolved once via the sourced sibling resolver (issue #247);
# best-effort — a copied/vendored deployment without lib/ falls back to bare
# `jq` with a breadcrumb rather than aborting under set -e.
# shellcheck source=resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

# devflow_filing_cap_verdict <status> <filed_this_run> <max_per_run> \
#                            <per_cat_count> <max_per_cat> <open_total> <max_open>
#
# Prints `file` when no cap withholds this pattern, else the name of the cap that
# withheld it (`max_issues_per_run` / `max_open_per_category` / `max_open_issues`).
# Always exits 0 — the verdict is the stdout token, so a caller never has to
# discriminate a withhold from a helper failure by exit status.
#
# Arm order is load-bearing and is asserted by the suite: per-run, then
# per-category, then the total-open cap. A `regressed` status bypasses
# `max_open_issues` only (a post-fix regression is the highest-value signal) and
# still honours the per-run and per-category caps.
#
# Fails CLOSED: any operand that is not a non-negative integer withholds under
# `invalid-operand` rather than filing on an unestablished count. A count that
# could not be derived is unknown, never zero — filing on it is the failure this
# guard exists to stop.
devflow_filing_cap_verdict() {
    if [ "$#" -ne 7 ]; then
        echo "invalid-operand" ; return 0
    fi
    local status="$1" filed_this_run="$2" max_per_run="$3" \
          per_cat_count="$4" max_per_cat="$5" open_total="$6" max_open="$7"
    local n
    for n in "$filed_this_run" "$max_per_run" "$per_cat_count" \
             "$max_per_cat" "$open_total" "$max_open"; do
        case "$n" in
            ''|*[!0-9]*) echo "invalid-operand" ; return 0 ;;
        esac
    done

    if [ "$filed_this_run" -ge "$max_per_run" ]; then
        echo "max_issues_per_run" ; return 0
    fi
    if [ "$per_cat_count" -ge "$max_per_cat" ]; then
        echo "max_open_per_category" ; return 0
    fi
    if [ "$status" != "regressed" ] && [ "$open_total" -ge "$max_open" ]; then
        echo "max_open_issues" ; return 0
    fi
    echo "file"
}

# devflow_liveness_warning <stderr-capture-file>
#
# Prints the human-readable body of the `liveness:` line actionable-patterns.sh
# wrote to stderr in Step 6, or nothing when the run emitted none. The report's
# liveness line (issue #788 AC) is rendered from this; without the capture the
# `::warning::` reaches the CI log but the report never names the count or the
# highest-occurrence slug.
#
# Parsed with bash builtins only — no tr/sed/wc/cut/head. This value reaches an
# emitted report line, and CLAUDE.md bars deriving such a value through a
# non-preflight PATH tool: a missing one would not fail, it would silently
# yield empty and drop the section. A missing or unreadable capture file prints
# nothing and exits 0 (the section is simply omitted).
devflow_liveness_warning() {
    local capture="${1:-}"
    [ -n "$capture" ] && [ -r "$capture" ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            'liveness: '*) printf '%s\n' "${line#liveness: }" ; return 0 ;;
        esac
    done < "$capture"
    return 0
}

# devflow_declined_refiled <overrides-path> <filed-slugs-json>
#
# Prints a JSON array of the slugs filed this run whose lifecycle record already
# held a meta-issue entry closed NOT_PLANNED — a maintainer's won't-fix the
# lifecycle deliberately re-raises on recurrence (issue #788). The report names
# each one alongside the one durable off-switch, so the decision is re-raised
# visibly rather than silently overridden.
#
# DUPLICATE is excluded deliberately: it is also a `declined` transition, but a
# duplicate closure records no won't-fix judgement to re-raise.
#
# The overrides file must be read BEFORE the run's own filings are appended,
# otherwise the entry this run just wrote (state `filed`) is all that is seen.
# Prints `[]` on any unreadable/malformed input — the section is omitted rather
# than the run aborted.
devflow_declined_refiled() {
    local ov="${1:-}" filed_json="${2:-[]}"
    if [ -z "$ov" ] || [ ! -r "$ov" ]; then
        printf '[]\n' ; return 0
    fi
    # `.` inside the select() below is the SLUG STRING, not the document, so the
    # record lookup binds the root first. Without $root the lookup reads
    # `null.patterns`, every select() is false, and the section silently never
    # renders — the same dead-wiring failure this helper exists to close.
    "$DEVFLOW_JQ" -c --argjson filed "$filed_json" '
        . as $root
        | [ $filed[]
            | . as $slug
            | select(
                (($root.patterns // {})[$slug].meta_issues // [])
                | any(.state == "declined" and .state_reason == "NOT_PLANNED")
              )
          ]' "$ov" 2>/dev/null || printf '[]\n'
}

# devflow_annotate_patterns <patterns-full-json-file> <filed-json> <withheld-json>
#
# Prints the unfiltered pattern view with each pattern carrying its filing
# outcome for this run and, where a cap withheld it, that cap (issue #788).
# render-report.sh reads `.filing_outcome` and `.withheld_by` per pattern; the
# `--full` view carries neither, so without this join those two reads render
# nothing on every pattern.
#
#   filed:    ["<slug>", ...]              — slugs an issue was filed for
#   withheld: [{"tag": "<slug>", "cap": "<cap>"}, ...]
#
# Every pattern carries an outcome (issue #788 AC): `issue filed`, `not filed`,
# or — for a withheld one — `withheld_by` alone, because the renderer already
# prints "withheld by `<cap>`" from that field and a `filing_outcome` of
# "withheld" beside it would render the word twice on the same line.
devflow_annotate_patterns() {
    local patterns_file="${1:-}" filed_json="${2:-[]}" withheld_json="${3:-[]}"
    if [ -z "$patterns_file" ] || [ ! -r "$patterns_file" ]; then
        printf '[]\n' ; return 0
    fi
    "$DEVFLOW_JQ" -c \
      --argjson filed "$filed_json" \
      --argjson withheld "$withheld_json" '
        ($withheld | map({key: (.tag // .slug // ""), value: (.cap // "")}) | from_entries) as $wmap
        | map(
            . as $p
            | ($p.tag // $p.slug // "") as $k
            | $p
            + (if ($filed | index($k)) then {filing_outcome: "issue filed"}
               elif ($wmap[$k] // "") != "" then {withheld_by: $wmap[$k]}
               else {filing_outcome: "not filed"} end)
          )' "$patterns_file" 2>/dev/null || printf '[]\n'
}

# devflow_open_filed_total <overrides-path>
# devflow_open_filed_in_category <overrides-path> <slug>
#
# The two comparands `devflow_filing_cap_verdict` reads: the count of `filed`
# meta-issue entries across every lifecycle record (the `max_open_issues`
# comparand), and the count within one record (the `max_open_per_category`
# comparand). Both are derived from the lifecycle state, never from a label
# query — a closed-but-still-labelled issue must not consume a cap slot.
#
# These live here rather than as inline jq in the skill for the same reason the
# cap arms do: a mis-shaped count decides whether an issue is filed, and inline
# jq in a prose surface is a decision the suite cannot catch defeated.
#
# Fails CLOSED by printing NOTHING (not `0`) on a missing, unreadable, or
# malformed overrides file, and on any jq failure. An unestablished count is
# unknown, never zero: `devflow_filing_cap_verdict` rejects the empty operand as
# `invalid-operand` and withholds, whereas a laundered `0` would report an empty
# backlog and file right past both caps.
devflow_open_filed_total() {
    local ov="${1:-}"
    [ -n "$ov" ] && [ -r "$ov" ] || return 0
    "$DEVFLOW_JQ" -r '
        [ (.patterns // {})[] | (.meta_issues // [])[] | select(.state == "filed") ] | length
      ' "$ov" 2>/dev/null || return 0
}

devflow_open_filed_in_category() {
    local ov="${1:-}" slug="${2:-}"
    [ -n "$ov" ] && [ -r "$ov" ] && [ -n "$slug" ] || return 0
    "$DEVFLOW_JQ" -r --arg s "$slug" '
        [ ((.patterns // {})[$s].meta_issues // [])[] | select(.state == "filed") ] | length
      ' "$ov" 2>/dev/null || return 0
}
