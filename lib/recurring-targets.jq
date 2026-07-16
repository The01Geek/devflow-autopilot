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
# missing either field (2/167 live entries lack suggested_interventions) or a
# clean entry carrying `suggested_interventions: []` contributes nothing and the
# reader never throws. Entries with no `pr` are skipped (a target's recurrence is
# measured across PRs, so an entry with no PR identity cannot contribute).

# Collect one record per (target, pr) pairing, preserving document order so the
# representative-summary tiebreak (ascending pr, then intervention order) is stable.
def pairs:
  [ .[]
    | select(.pr != null)
    | .pr as $pr
    | (.suggested_interventions // [])[]
    | (.summary // "") as $summary
    | (.candidate_targets // [])[]
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
