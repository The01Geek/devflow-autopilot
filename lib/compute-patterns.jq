# compute-patterns.jq — derives the per-pattern view from
# retrospectives.jsonl + overrides.json.
#
# This file is the spec author's substitute for a stored `patterns.json`:
# the view is fresh on every read, and there is no cached state to drift.
#
# Invocation:
#   jq -s -f lib/compute-patterns.jq \
#      --slurpfile overrides .devflow/learnings/overrides.json \
#      .devflow/learnings/retrospectives.jsonl
#
# Inputs:
#   stdin: array of retrospective entries (kind: "implementation" | "audit"),
#          obtained by passing -s (slurp) so JSONL becomes a single array.
#   $overrides: array containing one parsed overrides.json document.
#
# Output: an object keyed by category slug, each entry shaped as:
#   {
#     "first_seen": <iso8601 | null>,
#     "last_seen": <iso8601 | null>,
#     "occurrence_count": <int>,
#     "occurrences": [{"pr": <int>, "ts": <iso8601>, "verdict": "imperfect|blocked"}],
#     "descriptors": [<string>, ...],   # union of the occurrences' free-text descriptors
#     "status": "open" | "regressed" | "declined" | "filed" | "fixed" | "dismissed",
#     "fix_history": [{"pr": <int>, "ts": <iso8601>}]
#   }
#
# Grouping key: schema-v2 entries carry `categories` (a fixed vocabulary);
# legacy schema-v1 entries carry `theme_tags`. This file reads
# `(.categories // .theme_tags)` so both shapes count, and a mixed file
# (v1 entries from before the migration + v2 entries after) Just Works.
#
# Status derivation — six arms, evaluated in this order, first match wins (the
# status enum is closed, so this is complete by construction):
#   1. dismissed  — slug is a key in the human-owned overrides.dismissed{} map
#                   (the one absolute suppressor; no machine path writes it)
#   2. regressed  — an occurrence.merged_at strictly newer than the fix timestamp
#   3. declined   — the slug's lifecycle record (overrides.patterns{}) is `declined`
#                   (a meta-issue closed NOT_PLANNED / DUPLICATE) with no newer occurrence
#   4. filed      — the slug's lifecycle record is `filed` (an OPEN meta-issue)
#   5. fixed      — the slug's lifecycle record is `fixed`, OR (for a slug with NO
#                   record) the legacy audit fix_history is non-empty
#   6. open       — otherwise
#
# Fix-timestamp precedence (issue #788): for a slug that holds a lifecycle record
# in overrides.patterns{}, that record's `fixed_at` is the AUTHORITATIVE fix
# timestamp and the legacy `kind: "audit"` fix_history is NOT consulted for the
# regressed comparison; the legacy audit rows remain the fix-timestamp source
# only for a slug with no lifecycle record. This stops a frozen pre-#152 audit
# timestamp from outliving the lifecycle that replaced it, and introduces no
# second regression mechanism.
#
# `audit`-kind entries (the legacy fix_history read path) are LEGACY-DATA-ONLY:
# since #152 the loop files an issue per pattern and no longer opens autonomous
# audit PRs, so nothing produces new `audit` entries — `lib/audit-entry.jq` was
# removed. Historical `audit` rows in retrospectives.jsonl still parse here (so
# old fix_history is preserved); for new patterns, closure is tracked by the
# lifecycle record `lib/pattern-state.sh` reconciles against live meta-issue
# state, not by a permanent overrides.json dismissal.

# slugify — canonical slug used by the retrospective pipeline (the output object is
# keyed by this slug, so downstream consumers never re-derive it).
#   lowercase → kebab → truncate 40 → trim trailing dash
def slugify:
  ascii_downcase
  | gsub("[^a-z0-9]+"; "-")
  | gsub("-+"; "-")
  | ltrimstr("-") | rtrimstr("-")
  | .[0:40]
  | rtrimstr("-");

# Grouping tags for an implementation entry: v2 `categories`, falling back to
# v1 `theme_tags`. Defined once so occurrences_for and the tag-collection
# reducer stay in sync.
def grouping_tags: (.categories // .theme_tags) // [];

def occurrences_for($entries; $slug):
  [$entries[]
   | select(.kind == "implementation")
   | select(.verdict == "imperfect" or .verdict == "blocked")
   | select(grouping_tags | any(slugify == $slug))
   | select(.merged_at != null and .merged_at != "")
   | {pr: .pr, ts: .merged_at, verdict: .verdict}]
  | sort_by(.ts);

def descriptors_for($entries; $slug):
  [$entries[]
   | select(.kind == "implementation")
   | select(.verdict == "imperfect" or .verdict == "blocked")
   | select(grouping_tags | any(slugify == $slug))
   | (.descriptors // [])[]]
  | map(select(. != null and . != "")) | unique;

def fixes_for($entries; $slug):
  [$entries[]
   | select(.kind == "audit")
   | select((.fixes_patterns // []) | any(slugify == $slug))
   | select(.merged_at != null and .merged_at != "")
   | {pr: .pr, ts: .merged_at}]
  | sort_by(.ts);

. as $entries
| (($overrides[0] // {}) | .dismissed // {}) as $dismissed
# $records: the machine-owned v2 lifecycle map (overrides.patterns{}), keyed by
# category slug. Absent on a v1 file / a file pattern-state.sh has not migrated,
# in which case every slug falls through to the legacy fixed/regressed/open arms.
# Canonicalize the stored keys through the SAME slugify the membership test uses
# (issue #788: one canonicalization, so a non-canonical stored key cannot surface
# as a zero-occurrence phantom pattern).
| (($overrides[0] // {}) | .patterns // {}) as $records_raw
| ($records_raw | with_entries(.key |= slugify)) as $records
| ([
    ($entries[] | select(.kind == "implementation") | grouping_tags[] | slugify),
    ($entries[] | select(.kind == "audit") | (.fixes_patterns // [])[] | slugify),
    ($dismissed | keys[] | slugify),
    ($records | keys[])
  ] | unique) as $all_tags
| reduce $all_tags[] as $slug ({};
    occurrences_for($entries; $slug) as $occs
    | fixes_for($entries; $slug) as $fixes
    | ($records[$slug] // null) as $record
    | ($record.state // null) as $record_state
    # Fix-timestamp precedence: a lifecycle record's fixed_at is authoritative;
    # the legacy audit fix_history is the source only when no record exists.
    | (if $record != null then ($record.fixed_at // null) else (($fixes | last).ts // null) end) as $last_fix_ts
    | (($occs  | last).ts // null) as $last_occ_ts
    | (
        if   ($dismissed | has($slug)) then "dismissed"
        elif $last_fix_ts != null and $last_occ_ts != null and $last_occ_ts > $last_fix_ts then "regressed"
        # declined/filed/fixed are exactly the record-state values that pass through unchanged.
        elif ($record_state == "declined" or $record_state == "filed" or $record_state == "fixed") then $record_state
        elif $record == null and ($fixes | length) > 0 then "fixed"
        else "open"
        end
      ) as $status
    | . + {
        ($slug): {
          first_seen: (($occs | first).ts // null),
          last_seen:  $last_occ_ts,
          occurrence_count: ($occs | length),
          occurrences: $occs,
          descriptors: descriptors_for($entries; $slug),
          status: $status,
          fix_history: $fixes
        }
      }
  )
