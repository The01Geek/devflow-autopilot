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
#     "status": "dismissed" | "regressed" | "declined" | "filed" | "fixed" | "open",
#     "fix_history": [{"pr": <int>, "ts": <iso8601>}]
#   }
#
# Grouping key: schema-v2 entries carry `categories` (a fixed vocabulary);
# legacy schema-v1 entries carry `theme_tags`. This file reads
# `(.categories // .theme_tags)` so both shapes count, and a mixed file
# (v1 entries from before the migration + v2 entries after) Just Works.
#
# Status derivation (the six arms this file evaluates, complete by construction
# over the status enum, first match wins):
#   - tag in overrides.dismissed (the human map)   → "dismissed"
#   - newest occurrence.ts > fix timestamp         → "regressed"
#   - lifecycle record state == "declined"         → "declined"
#   - lifecycle record state == "filed"            → "filed"
#   - lifecycle record state == "fixed", OR (no
#     record and legacy fix_history non-empty)     → "fixed"
#   - otherwise                                    → "open"
#
# Fix-timestamp precedence (issue #788): for a slug that holds a lifecycle record
# in overrides.patterns[], that record's `fixed_at` is the authoritative fix
# timestamp and the legacy `kind: "audit"` rows for that slug are NOT consulted;
# the legacy rows remain the fix source only for a slug with no lifecycle record.
# This keeps historical fix_history readable without letting a frozen pre-#152
# audit timestamp outlive the lifecycle that replaced it, and introduces no second
# regression mechanism.
#
# `audit`-kind entries are a LEGACY-DATA-ONLY read path: since #152 the loop files
# an issue per pattern and no longer opens autonomous audit PRs, so nothing
# produces new `audit` entries. Historical `audit` rows still parse here (old
# fix_history is preserved) but are the fix source only for a slug with no
# lifecycle record. For new patterns, closure is via the issue-closure lifecycle
# `lib/pattern-state.sh` reconciles into overrides.patterns[] (issue #788), not the
# permanent `dismissed` write it replaced.

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
| ($overrides[0] // {}) as $ov
# Canonicalize BOTH lifecycle keys and dismissed keys through slugify ONCE, and
# test membership against those same canonical sets (issue #788): the key form
# injected into $all_tags is the key form membership is tested against, so a
# non-canonical stored key cannot surface as a zero-occurrence phantom pattern.
| (($ov.dismissed // {}) | to_entries | map({key:(.key|slugify), value:.value}) | from_entries) as $dismissed
| (($ov.patterns  // {}) | to_entries | map({key:(.key|slugify), value:.value}) | from_entries) as $lifecycle
| ([
    ($entries[] | select(.kind == "implementation") | grouping_tags[] | slugify),
    ($entries[] | select(.kind == "audit") | (.fixes_patterns // [])[] | slugify),
    ($dismissed | keys[]),
    ($lifecycle | keys[])
  ] | unique) as $all_tags
| reduce $all_tags[] as $slug ({};
    occurrences_for($entries; $slug) as $occs
    | fixes_for($entries; $slug) as $fixes
    | ($lifecycle[$slug] // null) as $rec
    # Fix-timestamp precedence: the lifecycle record's fixed_at when a record
    # exists (authoritative), else the legacy audit fix history.
    | (if $rec != null then $rec.fixed_at else (($fixes | last).ts // null) end) as $last_fix_ts
    | (($occs  | last).ts // null) as $last_occ_ts
    | (if $rec != null then $rec.state else null end) as $rec_state
    | (
        if   ($dismissed | has($slug)) then "dismissed"
        elif $last_fix_ts != null and $last_occ_ts != null and $last_occ_ts > $last_fix_ts then "regressed"
        elif $rec_state == "declined" then "declined"
        elif $rec_state == "filed" then "filed"
        elif $rec_state == "fixed" then "fixed"
        elif ($rec == null and ($fixes | length) > 0) then "fixed"
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
