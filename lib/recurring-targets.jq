# recurring-targets.jq — derives the "Recurring intervention targets" view from
# the accumulated retrospectives.jsonl (issue #520).
#
# This is a second, TARGET-keyed reader of the same store lib/compute-patterns.jq
# reads category-keyed. It surfaces the files/areas the retrospective's
# suggested_interventions[] repeatedly point at — the recurring "which areas keep
# needing fixes" signal the loop already collects but never surfaced. It is a pure,
# deterministic reader: no filing, no dismissal state, no producer-path change.
#
# Invocation (mirrors compute-patterns.jq — slurp the JSONL into one array):
#   jq -s -f lib/recurring-targets.jq .devflow/learnings/retrospectives.jsonl
#
# Input:
#   stdin: array of retrospective entries (kind: "implementation" | "audit"),
#          obtained by passing -s (slurp) so JSONL becomes a single array.
#
# Output: a JSON array of objects, one per target named in >= 2 DISTINCT PRs:
#   {
#     "target":                 <string>,   # exact candidate_targets[] path
#     "pr_count":               <int>,      # count of DISTINCT PRs naming it
#     "prs":                    [<int>...], # the distinct PR numbers, ascending
#     "representative_summary": <string>    # summary of the first intervention
#                                           #   naming the target (ascending PR,
#                                           #   then intervention document order)
#   }
#   sorted by descending pr_count, then target path ascending (deterministic).
#   The empty array [] when no target reaches >= 2 distinct PRs (or the store is
#   empty/absent — the caller pipes an empty stream in that case).
#
# Guards (issue #520 data-shape contract): both `.suggested_interventions` and
# each intervention's `.candidate_targets` are `// []`-guarded, so an entry
# missing either field (some live entries lack suggested_interventions) or a
# clean entry carrying `suggested_interventions: []` contributes nothing and the
# reader never throws. Only entries whose `pr` is a NUMBER contribute (a target's
# recurrence is measured across distinct PRs): a missing/null `pr` has no PR
# identity, and a wrong-typed `pr` — e.g. an agent-written string `"42"` — is
# dropped rather than counted as a PR distinct from the numeric `42`, which would
# otherwise inflate `pr_count` for a single real PR. Every agent-written field this
# reader EMITS is type-guarded at its source, so the emitted shape is total: `target`
# is always a non-empty string, and `representative_summary` is always a string — a
# wrong-typed summary would otherwise reach the CONSUMER's newline-flattening gsub in
# render-report.sh and abort the whole report render, since this reader's own rc-0
# "never throws" invariant does not extend to what downstream does with the value it
# emits. (Each guard's operative expression is at its site below, pinned by run.sh.)

# Collect one record per (target, pr) pairing, preserving document order so the
# representative-summary tiebreak (ascending pr, then intervention order) is stable.
def pairs:
  [ .[]
    # Best-effort-parser discipline: retrospectives.jsonl is agent-written, so an
    # entry (or either container field) can arrive WRONG-TYPED, not just missing.
    # `// []` only substitutes for null/missing — a present string/number/object
    # would still detonate the `[]` iterator (jq "Cannot iterate over …"). Guard the
    # CONTAINER type at each level (`objects` / `arrays` emit nothing for a
    # wrong-typed value) so a malformed line contributes nothing and the reader stays
    # exit-0, honoring the "never throws" invariant documented above.
    | objects
    # #626: `skip` marker entries (kind: "skip" — PR number + skip reason, no
    # suggested_interventions) are NOT retrospective analyses; they are processed-PR
    # bookkeeping. Exclude them by kind explicitly (this reader had no kind filter
    # before). A skip marker would contribute no pairs anyway (no candidate_targets),
    # but the explicit filter makes the exclusion a deliberate, pinned contract rather
    # than an accident of the missing-field guards.
    | select((.kind // "") != "skip")
    # `numbers` keeps only a number-typed `.pr` (drops missing/null AND a wrong-typed
    # string/bool `pr`), so a stray string `"42"` never counts as a PR distinct from 42.
    | select(.pr | numbers)
    | .pr as $pr
    | (.suggested_interventions // [] | arrays)[]
    | objects
    # Type-guard the summary exactly like `target`: an alternative-operator default
    # alone only substitutes for null/false, so a number/object/array summary
    # (reachable in an agent-written store) would flow through as
    # `representative_summary` and detonate the newline-flattening gsub in
    # render-report.sh (jq rc 5 on a non-string) — a hard abort of the whole render
    # under its `set -euo pipefail`, not a graceful omission. The `strings` filter
    # emits nothing for a non-string, so the default then yields "". (issue #520)
    | ((.summary | strings) // "") as $summary
    | (.candidate_targets // [] | arrays)[]
    # A target must be a non-empty string. `strings` drops any non-string element
    # (guard-class 2 / best-effort-parser discipline: retrospectives.jsonl is
    # agent-written, so a stray non-string candidate_target never becomes a target
    # or perturbs the sort's type ordering) before the empty-string check.
    | strings
    | select(. != "")
    | { target: ., pr: $pr, summary: $summary }
  ];

pairs
| group_by(.target)
| map(
    # sort_by is stable, so within a target the first element after sorting by pr
    # is the earliest-PR, earliest-intervention record — the representative choice.
    ( sort_by(.pr) ) as $g
    | {
        target: $g[0].target,
        prs: ([ $g[].pr ] | unique),          # unique sorts ascending → distinct PRs
        representative_summary: $g[0].summary
      }
    | .pr_count = (.prs | length)
  )
| map(select(.pr_count >= 2))
| sort_by([ -.pr_count, .target ])
