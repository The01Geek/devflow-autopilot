#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Tests for the lib/ jq filters and bash helpers. Run from repo root:
#   bash lib/test/run.sh
#
# Each test asserts a specific load-bearing invariant. A failure here means a
# downstream regression in the /devflow:retrospective-weekly orchestrator or the
# retrospective / retrospective-audit subagent briefs — keep these small and
# targeted, not exhaustive.

set -u

LIB="$(cd "$(dirname "$0")/.." && pwd)"

# Results are recorded to a file (one PASS/FAIL line each) rather than to shell
# variables, so assertions that run inside ( … ) subshells — the config-source.sh and
# render-report.sh blocks, sourced in subshells to contain their `set -e` — are
# counted in the final tally too. Counting in-memory would silently drop them.
RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo PASS >> "$RESULTS_FILE"
    printf '  PASS  %s\n' "$name"
  else
    echo FAIL >> "$RESULTS_FILE"
    printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' \
      "$name" "$expected" "$actual"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
echo "classify-pr-kind.jq"
# ────────────────────────────────────────────────────────────────────────────

classify() {
  jq -nr --arg branch "$1" --argjson watched "$2" --arg impl_prefix "${3:-claude/}" \
    -f "$LIB/classify-pr-kind.jq"
}

assert_eq "claude/ branch is implementation" \
  "implementation" \
  "$(classify "claude/issue-123-fix-thing" "true")"

assert_eq "devflow/audit- branch is audit-intervention" \
  "audit-intervention" \
  "$(classify "devflow/audit-foo-2026-05-01-abc1234" "true")"

assert_eq "claude/ branch with watched=false is skip" \
  "skip" \
  "$(classify "claude/issue-123-fix-thing" "false")"

assert_eq "devflow/learnings- branch is skip" \
  "skip" \
  "$(classify "devflow/learnings-2026-W18" "true")"

# ────────────────────────────────────────────────────────────────────────────
echo "compute-patterns.jq"
# ────────────────────────────────────────────────────────────────────────────

cp_run() {
  local entries="$1" overrides="$2"
  printf '%s\n' "$entries" \
  | jq -s --slurpfile overrides <(printf '%s' "$overrides") \
      -f "$LIB/compute-patterns.jq"
}

# Two open occurrences (schema-v2 `categories`) → status "open", count 2,
# and the descriptors of both occurrences are unioned into the pattern view.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit"],"descriptors":["orphaned fetch in handleEvent"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-10T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit","doc-accuracy"],"descriptors":["stale count not propagated"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "two open occurrences → status=open" \
  "open" \
  "$(echo "$RESULT" | jq -r '.["incomplete-edit"].status')"
assert_eq "two open occurrences → count=2" \
  "2" \
  "$(echo "$RESULT" | jq -r '.["incomplete-edit"].occurrence_count')"
assert_eq "descriptors unioned across occurrences" \
  "orphaned fetch in handleEvent|stale count not propagated" \
  "$(echo "$RESULT" | jq -r '.["incomplete-edit"].descriptors | sort | join("|")')"
assert_eq "a second category from the same PR forms its own pattern" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["doc-accuracy"].occurrence_count')"

# Legacy schema-v1 `theme_tags` entries still count (the `// .theme_tags`
# fallback in compute-patterns.jq) and slugify the same way as v2 categories,
# so a mixed file (pre- and post-migration entries) Just Works.
RESULT=$(cp_run \
  '{"schema_version":1,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","theme_tags":["doc-accuracy"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-10T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "v1 theme_tags + v2 categories grouped together (count=2)" \
  "2" \
  "$(echo "$RESULT" | jq -r '.["doc-accuracy"].occurrence_count')"

# One occ + later audit fix → status "fixed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["review-gate-bypass"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-04-15T00:00:00Z","fixes_patterns":["review-gate-bypass"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "occ then fix → status=fixed" \
  "fixed" \
  "$(echo "$RESULT" | jq -r '.["review-gate-bypass"].status')"

# Fix then later occ → status "regressed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"audit","pr":1,"merged_at":"2026-04-01T00:00:00Z","fixes_patterns":["convention-violation"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-15T00:00:00Z","verdict":"imperfect","categories":["convention-violation"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "fix then occ → status=regressed" \
  "regressed" \
  "$(echo "$RESULT" | jq -r '.["convention-violation"].status')"

# Override → status "dismissed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' \
  '{"schema_version":1,"dismissed":{"tooling-gap":{"reason":"meta-plugin-issue"}}}')
assert_eq "override → status=dismissed" \
  "dismissed" \
  "$(echo "$RESULT" | jq -r '.["tooling-gap"].status')"

# verdict:"blocked" entries also count as occurrences (alongside "imperfect").
# A simplification of the filter to drop "blocked" would silently make the
# whole "Blocked" workpad-status branch invisible to the audit.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"blocked","categories":["unmet-acceptance-criteria"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "blocked verdict counts as occurrence" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["unmet-acceptance-criteria"].occurrence_count')"

# Slug normalization is still applied defensively: a legacy mixed-case
# theme_tag slugifies to lowercase and matches a lowercase fixes_pattern.
RESULT=$(cp_run \
  '{"schema_version":1,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","theme_tags":["Foo-Bar-IN-Clause"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-04-15T00:00:00Z","fixes_patterns":["foo-bar-in-clause"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "slug normalization: mixed-case theme_tag matched by lowercase fixes_pattern → fixed" \
  "fixed" \
  "$(echo "$RESULT" | jq -r '.["foo-bar-in-clause"].status')"

# Missing merged_at MUST NOT contaminate first_seen/last_seen.
# An entry with no merged_at should be excluded from occurrences.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-15T00:00:00Z","verdict":"imperfect","categories":["other"]}
{"schema_version":2,"kind":"implementation","pr":2,"verdict":"imperfect","categories":["other"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "missing merged_at filtered out (count=1)" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["other"].occurrence_count')"
assert_eq "missing merged_at does not poison first_seen" \
  "2026-04-15T00:00:00Z" \
  "$(echo "$RESULT" | jq -r '.["other"].first_seen')"

# ────────────────────────────────────────────────────────────────────────────
echo "config-get.sh (resolver, direct)"
# ────────────────────────────────────────────────────────────────────────────
# The resolver is the single config-reading implementation (config-source.sh, workpad.py,
# match-deferrals.py all delegate to it), so its contract is tested directly here
# — config-source.sh's tests below can't observe exit codes (it swallows them by design).
CG="$LIB/../scripts/config-get.sh"
FIX="$LIB/test/fixtures/config.json"

assert_eq "cg: present scalar"          "claude,example-bot" "$("$CG" .claude.allowed_bots '' "$FIX")"
assert_eq "cg: nested int"              "2"                   "$("$CG" .devflow_retrospective.min_occurrences '' "$FIX")"
assert_eq "cg: array → comma-join"      "claude,example-bot" "$("$CG" .devflow_retrospective.watched_authors '' "$FIX")"
assert_eq "cg: leading dot optional"    "2"                   "$("$CG" devflow_retrospective.min_occurrences '' "$FIX")"
assert_eq "cg: missing key → default"   "fallback"           "$("$CG" .a.b.c fallback "$FIX")"
assert_eq "cg: descend into scalar → default" "dfl"          "$("$CG" .claude.allowed_bots.nope dfl "$FIX")"
assert_eq "cg: missing file → default"  "dfl"                "$("$CG" .x dfl /no/such/config.json)"

# Exit-code contract (run.sh uses `set -u`, not `set -e`, so a nonzero is safe).
"$CG" .a.b.c '' "$FIX" >/dev/null 2>&1
assert_eq "cg: missing key + empty default → exit 0" "0" "$?"
# Run from an empty cwd so the default config path is deterministically absent
# (don't couple this to the repo's live .devflow/config.json being valid JSON).
( cd "$(mktemp -d)" && "$CG" .nope.nope >/dev/null 2>&1 )
assert_eq "cg: missing key/file + no default → exit 1" "1" "$?"
"$CG" "" >/dev/null 2>&1
assert_eq "cg: empty KEY → exit 2" "2" "$?"
CG_BAD="$(mktemp)"; printf '{ not valid json' > "$CG_BAD"
"$CG" .a fallback "$CG_BAD" >/dev/null 2>&1
assert_eq "cg: invalid JSON → exit 2" "2" "$?"
rm -f "$CG_BAD"

# ────────────────────────────────────────────────────────────────────────────
echo "scaffold-config.sh"
# ────────────────────────────────────────────────────────────────────────────
# Single shared scaffolder used by BOTH install.sh and the /devflow:init skill.
# Templates resolve relative to the script (../.devflow), so we point it at a
# throwaway TARGET root and assert against the repo's real template files.
SC="$LIB/../scripts/scaffold-config.sh"
TPL_DIR="$LIB/../.devflow"

# 1. Fresh target → scaffolds config.json (from the example) + schema.
SC_FRESH="$(mktemp -d)"
bash "$SC" "$SC_FRESH" >/dev/null 2>&1
assert_eq "scaffold: fresh exit 0" "0" "$?"
assert_eq "scaffold: config.json created" "yes" \
  "$([ -f "$SC_FRESH/.devflow/config.json" ] && echo yes || echo no)"
assert_eq "scaffold: config.json == example template" \
  "$(cat "$TPL_DIR/config.example.json")" "$(cat "$SC_FRESH/.devflow/config.json")"
assert_eq "scaffold: schema created" "yes" \
  "$([ -f "$SC_FRESH/.devflow/config.schema.json" ] && echo yes || echo no)"
# Scoped scratch ignore: created, ignores ONLY tmp/ (so config.json + learnings
# stay committable — never the .devflow/ root).
assert_eq "scaffold: .devflow/.gitignore created" "yes" \
  "$([ -f "$SC_FRESH/.devflow/.gitignore" ] && echo yes || echo no)"
assert_eq "scaffold: .gitignore ignores tmp/" "yes" \
  "$(grep -qxF '/tmp/' "$SC_FRESH/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "scaffold: .gitignore does NOT ignore the .devflow root" "no" \
  "$(grep -qE '^/?\*?$|^\.$' "$SC_FRESH/.devflow/.gitignore" && echo yes || echo no)"

# 2. Existing config.json + .gitignore → NEVER clobbered; schema still refreshed.
SC_KEEP="$(mktemp -d)"
mkdir -p "$SC_KEEP/.devflow"
printf '{"sentinel":true}' > "$SC_KEEP/.devflow/config.json"
printf 'STALE' > "$SC_KEEP/.devflow/config.schema.json"
printf 'CUSTOM-IGNORE\n' > "$SC_KEEP/.devflow/.gitignore"
bash "$SC" "$SC_KEEP" >/dev/null 2>&1
assert_eq "scaffold: existing config preserved" \
  '{"sentinel":true}' "$(cat "$SC_KEEP/.devflow/config.json")"
assert_eq "scaffold: schema refreshed over stale" \
  "$(cat "$TPL_DIR/config.schema.json")" "$(cat "$SC_KEEP/.devflow/config.schema.json")"
assert_eq "scaffold: existing .gitignore preserved" \
  'CUSTOM-IGNORE' "$(cat "$SC_KEEP/.devflow/.gitignore")"

# 3. Idempotent: a second run leaves the scaffolded config.json AND the
#    scaffolder's OWN .gitignore byte-identical (guards the `if [ ! -f ]` create
#    guard against a regression that re-writes/appends on every run).
SC_B1="$(cat "$SC_FRESH/.devflow/config.json")"
SC_GI1="$(cat "$SC_FRESH/.devflow/.gitignore")"
bash "$SC" "$SC_FRESH" >/dev/null 2>&1
assert_eq "scaffold: idempotent re-run keeps config" \
  "$SC_B1" "$(cat "$SC_FRESH/.devflow/config.json")"
assert_eq "scaffold: idempotent re-run keeps .gitignore" \
  "$SC_GI1" "$(cat "$SC_FRESH/.devflow/.gitignore")"

# 4. Templates missing next to the script → fail loudly (exit 2), no guessing.
SC_NOTPL="$(mktemp -d)"; mkdir -p "$SC_NOTPL/scripts"
cp "$SC" "$SC_NOTPL/scripts/scaffold-config.sh"
SC_NOTPL_TGT="$(mktemp -d)"
bash "$SC_NOTPL/scripts/scaffold-config.sh" "$SC_NOTPL_TGT" >/dev/null 2>&1
assert_eq "scaffold: missing templates → exit 2" "2" "$?"

rm -rf "$SC_FRESH" "$SC_KEEP" "$SC_NOTPL" "$SC_NOTPL_TGT"

# ────────────────────────────────────────────────────────────────────────────
echo "config-source.sh"
# ────────────────────────────────────────────────────────────────────────────
( export DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json"
  . "$LIB/config-source.sh"
  assert_eq "watched authors from config" "claude,example-bot" "$(devflow_watched_authors)"
  assert_eq "min_occurrences from config" "2" "$(devflow_conf '.devflow_retrospective.min_occurrences' 99)"
  assert_eq "missing key → default" "fallback" "$(devflow_conf '.devflow_retrospective.nonexistent_key_xyz' fallback)"
)
# Resilience: config-source.sh runs under `set -e`; a missing or malformed config must
# return the default without aborting the sourcing chain.
( export DEVFLOW_CONFIG_FILE="/no/such/devflow/config.json"
  . "$LIB/config-source.sh"
  assert_eq "conf: missing file → default (no abort)" "dflt" "$(devflow_conf '.anything' dflt)"
)
( wp="$(mktemp)"; printf '{ not valid json' > "$wp"
  export DEVFLOW_CONFIG_FILE="$wp"
  . "$LIB/config-source.sh"
  assert_eq "conf: malformed JSON → default (warns, no abort)" "dflt" "$(devflow_conf '.anything' dflt 2>/dev/null)"
  rm -f "$wp"
)
# watched_authors falls back to claude.allowed_bots when the override array is absent.
( wp="$(mktemp)"; printf '{"claude":{"allowed_bots":"claude,fallback-bot"}}' > "$wp"
  export DEVFLOW_CONFIG_FILE="$wp"
  . "$LIB/config-source.sh"
  assert_eq "conf: watched_authors → allowed_bots fallback" "claude,fallback-bot" "$(devflow_watched_authors)"
  rm -f "$wp"
)

# ────────────────────────────────────────────────────────────────────────────
echo "scan.sh"
# ────────────────────────────────────────────────────────────────────────────
SCAN_TMP="$(mktemp -d)"
cat > "$SCAN_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"author:claude"*)
    echo '[{"number":1,"headRefName":"claude/issue-1-a","author":{"login":"claude"},"mergedAt":"2026-05-01T00:00:00Z"},
           {"number":3,"headRefName":"claude/issue-3-c","author":{"login":"claude"},"mergedAt":"2026-05-03T00:00:00Z"},
           {"number":9,"headRefName":"devflow/learnings-2026-W18","author":{"login":"example-bot"},"mergedAt":"2026-05-02T00:00:00Z"}]' ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*)
    BODY="$(printf '{"pr":1}\n{"pr":2}\n' | base64 | tr -d "\n")"
    printf 'HTTP/2.0 200 OK\r\n\r\n{"content":"%s"}\n' "$BODY" ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh"
SCAN_OUT="$(DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh" bash "$LIB/scan.sh" 2>/dev/null)"
assert_eq "scan includes unprocessed PR 3"        "true"  "$(echo "$SCAN_OUT" | jq 'any(.[]; .number==3)')"
assert_eq "scan excludes already-recorded PR 1"   "false" "$(echo "$SCAN_OUT" | jq 'any(.[]; .number==1)')"
assert_eq "scan excludes devflow/learnings branch" "false" "$(echo "$SCAN_OUT" | jq 'any(.[]; .number==9)')"

# #7a: --prs ad-hoc mode — explicit numbers, no search, no processed-filter;
# still drops non-merged / non-retrospected branches.
cat > "$SCAN_TMP/gh2" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view 1 --repo"*) echo '{"number":1,"headRefName":"claude/issue-1-a","mergedAt":"2026-05-01T00:00:00Z","state":"MERGED"}' ;;
  *"pr view 2 --repo"*) echo '{"number":2,"headRefName":"feature/hand-written","mergedAt":"2026-05-02T00:00:00Z","state":"MERGED"}' ;;
  *"pr view 3 --repo"*) echo '{"number":3,"headRefName":"claude/issue-3-c","mergedAt":"2026-05-03T00:00:00Z","state":"OPEN"}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh2"
PRS_OUT="$(DEVFLOW_GH="$SCAN_TMP/gh2" bash "$LIB/scan.sh" --prs "1,2,3" 2>/dev/null)"
assert_eq "--prs includes explicit merged retrospected PR 1" "true"  "$(echo "$PRS_OUT" | jq 'any(.[]; .number==1)')"
assert_eq "--prs drops non-retrospected branch PR 2"        "false" "$(echo "$PRS_OUT" | jq 'any(.[]; .number==2)')"
assert_eq "--prs drops non-merged PR 3"                     "false" "$(echo "$PRS_OUT" | jq 'any(.[]; .number==3)')"
assert_eq "--prs ignores already-processed retrospectives.jsonl (PR 1 from gh stub matches an EXISTING pr in weekly mode but here is kept)" "1" "$(echo "$PRS_OUT" | jq 'length')"
rm -rf "$SCAN_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "fetch-pr-context.sh"
# ────────────────────────────────────────────────────────────────────────────
GH_STUB="$LIB/test/fixtures/gh-stub.sh"
OUT="$(DEVFLOW_GH="$GH_STUB" DEVFLOW_FIXTURE_PR=793 bash "$LIB/fetch-pr-context.sh" 793)"
CTX="$(cat "$OUT")"
assert_eq "kind=implementation"            "implementation" "$(jq -r .kind            <<<"$CTX")"
assert_eq "issue_number parsed"            "790"            "$(jq -r '.issue_number'   <<<"$CTX")"
assert_eq "review_comments_count=0"        "0"              "$(jq -r '.signals.review_comments_count' <<<"$CTX")"
assert_eq "post_bot_commits=4"             "4"              "$(jq -r '.signals.post_bot_commits'      <<<"$CTX")"
assert_eq "ci_failures=1"                  "1"              "$(jq -r '.signals.ci_failures_during_pr' <<<"$CTX")"
assert_eq "workpad_final_status=Complete"  "Complete"       "$(jq -r '.signals.workpad_final_status'  <<<"$CTX")"
assert_eq "review_reject_outstanding=true" "true"           "$(jq -r '.signals.review_reject_outstanding' <<<"$CTX")"
OUTC="$(DEVFLOW_GH="$GH_STUB" DEVFLOW_FIXTURE_PR=CLEAN bash "$LIB/fetch-pr-context.sh" 4242)"
CTXC="$(cat "$OUTC")"
assert_eq "clean: reject_outstanding=false" "false" "$(jq -r '.signals.review_reject_outstanding' <<<"$CTXC")"
assert_eq "clean: post_bot_commits=0"       "0"     "$(jq -r '.signals.post_bot_commits'      <<<"$CTXC")"
assert_eq "clean: ci_failures=0"            "0"     "$(jq -r '.signals.ci_failures_during_pr' <<<"$CTXC")"
assert_eq "ci_status_unknown=false (793 fixture)"   "false" "$(jq -r '.signals.ci_status_unknown' <<<"$CTX")"
assert_eq "ci_status_unknown=false (CLEAN fixture)"  "false" "$(jq -r '.signals.ci_status_unknown' <<<"$CTXC")"
# Fix 2: diff field must be a non-null string when the fixture has content
assert_eq "diff is a non-empty string" "string" "$(jq -r '.diff | type' <<<"$CTX")"
assert_eq "diff not null"              "false"  "$(jq -r '.diff == null' <<<"$CTX")"

# #1: post_bot_commits / human_postbot SHA list count only *substantive* (non-merge)
# commits after the bot's last commit. A `git merge main` by a human (parents>1)
# is branch hygiene, not a fixup, and must not be counted.
_postbot_count() {  # stdin: COMMITS-shaped array; arg1: PR-author login
  jq --arg author "$1" '
    to_entries
    | [.[] | select(
        (.value.author_login | endswith("[bot]"))
        or (.value.committer_login | endswith("[bot]"))
        or (.value.author_login == $author)
        or (.value.committer_login == $author)
      ) | .key
    ] as $bot
    | if ($bot | length) == 0 then 0
      else ([.[($bot | last) + 1:][] | select((.value.parents_count // 1) <= 1)] | length)
      end'
}
assert_eq "post_bot: merge commit excluded, real fixup counted" "1" \
  "$(echo '[{"author_login":"claude[bot]","committer_login":"web-flow","parents_count":1},{"author_login":"alice","committer_login":"alice","parents_count":2},{"author_login":"alice","committer_login":"alice","parents_count":1}]' | _postbot_count someoneelse)"
assert_eq "post_bot: only a human merge after the bot → 0" "0" \
  "$(echo '[{"author_login":"claude[bot]","committer_login":"web-flow","parents_count":1},{"author_login":"alice","committer_login":"alice","parents_count":2}]' | _postbot_count someoneelse)"
assert_eq "post_bot: missing parents_count treated as non-merge (counted)" "1" \
  "$(echo '[{"author_login":"claude[bot]","committer_login":"web-flow"},{"author_login":"alice","committer_login":"alice"}]' | _postbot_count someoneelse)"

# #4: the /review verdict parser must recognize BOTH the standalone `/review`
# report heading (`## Verdict: APPROVE (…)`) and the CI `@claude run /review`
# wrapper heading (`### /review — Verdict: **REJECT**`), and must NOT fire on a
# prose mention of the word "verdict".
_vparse() {
  jq -r '
    [ .[] | . as $c | (.body//"") | split("\n")[] | rtrimstr("\r")
      | select(test("^#{1,6}[ \t]*(/review[ \t]*[—–-]+[ \t]*)?Verdict:[ \t]*\\**[ \t]*(APPROVE|REJECT)"; "i"))
      | capture("Verdict:[ \t]*\\**[ \t]*(?<verdict>APPROVE|REJECT)"; "i")
      | {verdict:(.verdict|ascii_upcase), createdAt:$c.created_at} ]
    | (.[-1].verdict // "NONE")'
}
assert_eq "verdict parser: CI wrapper format" "REJECT" \
  "$(echo '[{"body":"**Claude finished** ——\n\n---\n### /review — Verdict: **REJECT**\n\nblah","created_at":"2026-01-01T00:00:00Z"}]' | _vparse)"
assert_eq "verdict parser: standalone format" "APPROVE" \
  "$(echo '[{"body":"# Review Report\n\n## Verdict: APPROVE (looks good)\n","created_at":"2026-01-02T00:00:00Z"}]' | _vparse)"
assert_eq "verdict parser: APPROVE WITH CAVEAT → APPROVE" "APPROVE" \
  "$(echo '[{"body":"## Verdict: APPROVE WITH CAVEAT — checklist not generated\n","created_at":"2026-01-03T00:00:00Z"}]' | _vparse)"
assert_eq "verdict parser: prose mention ignored" "NONE" \
  "$(echo '[{"body":"I think the verdict: REJECT was harsh.","created_at":"2026-01-04T00:00:00Z"}]' | _vparse)"

# #5: fetch-pr-context elides generated/vendored file bodies from the embedded
# diff but keeps every path in changed_files.
_DIFF_SAMPLE='diff --git a/src/Foo.php b/src/Foo.php
@@ -1 +1 @@
-x
+y
diff --git a/package-lock.json b/package-lock.json
@@ -1,9 +1,9 @@
- noise
+ noise
diff --git a/jsx/dist/app.min.js b/jsx/dist/app.min.js
@@ -1 +1 @@
-a
+b'
_DIFF_TRIMMED="$(printf '%s' "$_DIFF_SAMPLE" | python3 -c '
import sys, re
diff = sys.stdin.read()
noise = re.compile(r"(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Gemfile\.lock|poetry\.lock|Cargo\.lock|go\.sum)$|\.min\.(js|css|mjs)$|\.map$|(^|/)(node_modules|vendor|dist|build)/")
out, elide = [], False
for line in diff.split("\n"):
    if line.startswith("diff --git "):
        parts = line.split(" ", 3)
        path = parts[2][2:] if len(parts) > 2 and parts[2].startswith("a/") else ""
        elide = bool(path and noise.search(path))
        if elide:
            out.append(line); out.append("[elided: %s]" % path); continue
    if not elide: out.append(line)
sys.stdout.write("\n".join(out))
')"
assert_eq "diff trim: real source kept"       "true"  "$(printf '%s' "$_DIFF_TRIMMED" | grep -qx -- '+y' && echo true || echo false)"
assert_eq "diff trim: lockfile body elided"   "true"  "$(printf '%s' "$_DIFF_TRIMMED" | grep -q '\[elided: package-lock.json\]' && echo true || echo false)"
assert_eq "diff trim: lockfile noise removed"  "false" "$(printf '%s' "$_DIFF_TRIMMED" | grep -q -- '- noise' && echo true || echo false)"
assert_eq "diff trim: minified bundle elided"  "true"  "$(printf '%s' "$_DIFF_TRIMMED" | grep -q '\[elided: jsx/dist/app.min.js\]' && echo true || echo false)"

# ────────────────────────────────────────────────────────────────────────────
echo "cheap-gate.jq"
# ────────────────────────────────────────────────────────────────────────────
gate() { jq -c -f "$LIB/cheap-gate.jq"; }
BASE='{"signals":{"review_comments_count":0,"post_bot_commits":0,"ci_failures_during_pr":0,"ci_status_unknown":false,"workpad_final_status":"Complete","review_reject_outstanding":false}}'
assert_eq "all clean → clean=true"            "true"  "$(echo "$BASE" | gate | jq -r .clean)"
assert_eq "reject outstanding → clean=false"  "false" "$(echo "$BASE" | jq '.signals.review_reject_outstanding=true' | gate | jq -r .clean)"
assert_eq "ci failure → clean=false"          "false" "$(echo "$BASE" | jq '.signals.ci_failures_during_pr=1' | gate | jq -r .clean)"
assert_eq "ci_status_unknown=true → clean=false" "false" "$(echo "$BASE" | jq '.signals.ci_status_unknown=true' | gate | jq -r .clean)"
assert_eq "ci_status_unknown=true reason"     "CI status could not be read" "$(echo "$BASE" | jq '.signals.ci_status_unknown=true' | gate | jq -r .reason)"
assert_eq "human commit → clean=false"        "false" "$(echo "$BASE" | jq '.signals.post_bot_commits=2' | gate | jq -r .clean)"
assert_eq "review comment → clean=false"      "false" "$(echo "$BASE" | jq '.signals.review_comments_count=1' | gate | jq -r .clean)"
assert_eq "workpad Blocked → clean=false"     "false" "$(echo "$BASE" | jq '.signals.workpad_final_status="Blocked"' | gate | jq -r .clean)"
assert_eq "workpad empty string → clean=true" "true"  "$(echo "$BASE" | jq '.signals.workpad_final_status=""' | gate | jq -r .clean)"
assert_eq "workpad null → clean=true"         "true"  "$(echo "$BASE" | jq '.signals.workpad_final_status=null' | gate | jq -r .clean)"

# ────────────────────────────────────────────────────────────────────────────
echo "clean-entry.jq / audit-entry.jq / actionable-patterns.sh"
# ────────────────────────────────────────────────────────────────────────────
CTX_CLEAN='{"pr":42,"kind":"implementation","issue_number":40,"merged_at":"2026-05-01T00:00:00Z","branch":"claude/issue-40-x","head_sha":"abc","merge_commit_sha":"def","signals":{"review_comments_count":0,"post_bot_commits":0,"ci_failures_during_pr":0,"workpad_final_status":"Complete","review_reject_outstanding":false}}'
E="$(echo "$CTX_CLEAN" | jq -c -f "$LIB/clean-entry.jq")"
assert_eq "clean-entry verdict=clean"       "clean" "$(echo "$E" | jq -r .verdict)"
assert_eq "clean-entry pr=42"               "42"    "$(echo "$E" | jq -r .pr)"
assert_eq "clean-entry schema_version=2"    "2"     "$(echo "$E" | jq -r .schema_version)"
assert_eq "clean-entry categories=[]"       "0"     "$(echo "$E" | jq '.categories|length')"
assert_eq "clean-entry descriptors=[]"      "0"     "$(echo "$E" | jq '.descriptors|length')"
assert_eq "clean-entry no theme_tags field" "true"  "$(echo "$E" | jq 'has("theme_tags") | not')"
assert_eq "clean-entry signals carried"     "0"     "$(echo "$E" | jq -r .signals.post_bot_commits)"
CTX_AUDIT='{"pr":99,"kind":"audit-intervention","pattern_tag":"review-gate-bypass","merged_at":"2026-05-09T00:00:00Z"}'
A="$(echo "$CTX_AUDIT" | jq -c -f "$LIB/audit-entry.jq")"
assert_eq "audit-entry kind=audit"        "audit"              "$(echo "$A" | jq -r .kind)"
assert_eq "audit-entry schema_version=2"  "2"                  "$(echo "$A" | jq -r .schema_version)"
assert_eq "audit-entry fixes_patterns"    "review-gate-bypass" "$(echo "$A" | jq -r '.fixes_patterns[0]')"
# actionable-patterns: incomplete-edit 2x imperfect, doc-accuracy 1x
AP_TMP="$(mktemp -d)"
printf '%s\n' \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit"],"descriptors":["orphaned fetch left after deletion"]}' \
  '{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-10T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit"],"descriptors":["stale count not propagated"]}' \
  '{"schema_version":2,"kind":"implementation","pr":3,"merged_at":"2026-04-11T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' \
  > "$AP_TMP/r.jsonl"
echo '{"schema_version":1,"dismissed":{}}' > "$AP_TMP/o.json"
cat > "$AP_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"pr list"*) echo '[]' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh"
AP="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json")"
assert_eq "actionable includes incomplete-edit"        "true"  "$(echo "$AP" | jq 'any(.[]; .tag=="incomplete-edit")')"
assert_eq "actionable excludes doc-accuracy (1<2)"     "false" "$(echo "$AP" | jq 'any(.[]; .tag=="doc-accuracy")')"
assert_eq "incomplete-edit occurrence_count=2"         "2"     "$(echo "$AP" | jq '.[] | select(.tag=="incomplete-edit") | .occurrence_count')"
assert_eq "incomplete-edit descriptors passed through" "orphaned fetch left after deletion|stale count not propagated" \
  "$(echo "$AP" | jq -r '.[] | select(.tag=="incomplete-edit") | .descriptors | sort | join("|")')"
assert_eq "incomplete-edit cooldown_active=false"      "false" "$(echo "$AP" | jq '.[] | select(.tag=="incomplete-edit") | .cooldown_active')"
# now an open audit PR for incomplete-edit created today → cooldown_active true
cat > "$AP_TMP/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in *"pr list"*) echo '[{"number":500,"headRefName":"devflow/audit-incomplete-edit-'"$(date -u +%F)"'-abc1234","createdAt":"'"$(date -u +%FT%TZ)"'"}]' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh"
AP2="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json")"
assert_eq "incomplete-edit cooldown_active=true after recent audit PR" "true" "$(echo "$AP2" | jq '.[] | select(.tag=="incomplete-edit") | .cooldown_active')"
# Missing overrides.json → should still emit the actionable array, not error
AP_NOOV="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "/tmp/devflow-nonexistent-overrides-$$-$RANDOM.json")" \
  && assert_eq "actionable: missing overrides → incomplete-edit still present" "true" "$(echo "$AP_NOOV" | jq 'any(.[]; .tag=="incomplete-edit")')" \
  || { echo FAIL >> "$RESULTS_FILE"; printf '  FAIL  actionable: missing overrides → script errored\n'; }
rm -rf "$AP_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "materialize-retrospectives.sh"
# ────────────────────────────────────────────────────────────────────────────
M_TMP="$(mktemp -d)"
printf '%s\n' \
  '{"pr":1,"kind":"implementation","verdict":"clean","note":"old"}' \
  '{"pr":2,"kind":"implementation","verdict":"imperfect"}' \
  > "$M_TMP/r.jsonl"
printf '%s\n' \
  '{"pr":1,"kind":"implementation","verdict":"imperfect","note":"new"}' \
  '{"pr":5,"kind":"implementation","verdict":"clean"}' \
  '{"pr":2,"kind":"audit","fixes_patterns":["t-z"]}' \
  > "$M_TMP/new.jsonl"
SUMMARY="$(bash "$LIB/materialize-retrospectives.sh" "$M_TMP/new.jsonl" "$M_TMP/r.jsonl")"
assert_eq "materialize: 4 lines after merge"      "4" "$(wc -l < "$M_TMP/r.jsonl" | tr -d ' ')"
assert_eq "materialize: pr1 replaced (note=new)"  "new" "$(grep '"pr":1' "$M_TMP/r.jsonl" | jq -r 'select(.pr==1 and .kind=="implementation") | .note')"
assert_eq "materialize: pr5 appended"             "true" "$([ -n "$(jq -c 'select(.pr==5)' "$M_TMP/r.jsonl")" ] && echo true || echo false)"
assert_eq "materialize: pr2 audit appended (impl kept)" "2" "$(jq -s '[.[]|select(.pr==2)]|length' "$M_TMP/r.jsonl")"
assert_eq "materialize: valid jsonl" "0" "$(jq -c . "$M_TMP/r.jsonl" >/dev/null 2>&1; echo $?)"
assert_eq "materialize: summary mentions replaced 1" "1" "$(echo "$SUMMARY" | grep -oE 'replaced [0-9]+' | grep -oE '[0-9]+')"
# Fix 5: missing new-entries file → should print "materialized: appended 0, replaced 0" and exit 0
M_NOFILE_TMP="$(mktemp -d)"
printf '%s\n' '{"pr":10,"kind":"implementation","verdict":"clean"}' > "$M_NOFILE_TMP/existing.jsonl"
M_NOFILE_OUT="$(bash "$LIB/materialize-retrospectives.sh" "/tmp/devflow-nonexistent-new-entries-$$-$RANDOM.jsonl" "$M_NOFILE_TMP/existing.jsonl")"
assert_eq "materialize: missing new-entries → appended 0, replaced 0" "materialized: appended 0, replaced 0" "$M_NOFILE_OUT"
assert_eq "materialize: missing new-entries → target untouched" "1" "$(wc -l < "$M_NOFILE_TMP/existing.jsonl" | tr -d ' ')"
rm -rf "$M_NOFILE_TMP"
rm -rf "$M_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "check-excluded-path.sh"
# ────────────────────────────────────────────────────────────────────────────
ex() { bash "$LIB/check-excluded-path.sh" "$@" >/dev/null 2>&1; echo $?; }
assert_eq "adopter .claude/skills file allowed" "1" "$(ex ".claude/skills/example/SKILL.md")"
assert_eq "CLAUDE.md allowed"             "1" "$(ex "CLAUDE.md")"
assert_eq "docs allowed"                  "1" "$(ex "docs/internal/foo.md")"
assert_eq "app source allowed"            "1" "$(ex "src/app.py")"
assert_eq "engine skill path excluded"    "0" "$(ex "skills/retrospective/SKILL.md")"
assert_eq "engine lib path excluded"      "0" "$(ex "lib/scan.sh")"
assert_eq "engine agents path excluded"   "0" "$(ex "agents/checklist-generator.md")"
assert_eq "engine scripts path excluded"  "0" "$(ex "scripts/workpad.py")"
assert_eq "plugin manifest excluded"      "0" "$(ex ".claude-plugin/plugin.json")"
assert_eq "devflow workflow excluded"     "0" "$(ex ".github/workflows/devflow-doc-audit.yml")"
assert_eq "claude.yml excluded"           "0" "$(ex ".github/workflows/claude.yml")"
assert_eq "claude-runner.yml excluded"    "0" "$(ex ".github/workflows/claude-runner.yml")"
assert_eq "non-engine workflow allowed"   "1" "$(ex ".github/workflows/release.yml")"
assert_eq "config.json excluded"          "0" "$(ex ".devflow/config.json")"
assert_eq "config.example excluded"       "0" "$(ex ".devflow/config.example.json")"
assert_eq "config.schema excluded"        "0" "$(ex ".devflow/config.schema.json")"
assert_eq "learnings data excluded"       "0" "$(ex ".devflow/learnings/overrides.json")"
assert_eq "composite action excluded"     "0" "$(ex ".github/actions/read-project-config/action.yml")"
assert_eq "stdin mode works"              "0" "$(printf '%s\n' 'CLAUDE.md' '.devflow/learnings/x.json' | bash "$LIB/check-excluded-path.sh" >/dev/null 2>&1; echo $?)"
assert_eq "mixed all-allowed → exit 1"    "1" "$(ex "CLAUDE.md" ".claude/skills/x/SKILL.md")"
assert_eq "prints the excluded path"      ".devflow/learnings/x.json" "$(bash "$LIB/check-excluded-path.sh" "CLAUDE.md" ".devflow/learnings/x.json")"

# ────────────────────────────────────────────────────────────────────────────
echo "meta-issue.sh"
# ────────────────────────────────────────────────────────────────────────────
MI_TMP="$(mktemp -d)"
echo '{"schema_version":1,"dismissed":{}}' > "$MI_TMP/ov.json"
echo 'Proposed: strengthen the cheap gate.' > "$MI_TMP/body.md"
cat > "$MI_TMP/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"issue list"*) echo '' ;;                                # no existing issue
  *"issue create"*) printf '%s' "\$*" > "$MI_TMP/create-args"; echo 'https://github.com/acme/example-repo/issues/4242' ;;
  *"issue comment"*) echo 'commented' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
URL="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag review-reject-bypassed --slug review-reject-bypassed --title "audit(devflow): x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov.json" 2>/dev/null)"
assert_eq "meta-issue returns the new URL" "https://github.com/acme/example-repo/issues/4242" "$URL"
# Created title must keep the de-dup key prefix (Step-1 search matches it) AND
# carry the caller's --title (regression: --title was previously discarded).
assert_eq "create title keeps the de-dup key" "true" \
  "$(grep -qF -- '--title [devflow-retrospective] meta: review-reject-bypassed' "$MI_TMP/create-args" && echo true || echo false)"
assert_eq "create title carries the caller --title" "true" \
  "$(grep -qF -- 'audit(devflow): x' "$MI_TMP/create-args" && echo true || echo false)"
assert_eq "override recorded with url"     "https://github.com/acme/example-repo/issues/4242" "$(jq -r '.dismissed["review-reject-bypassed"].meta_issue' "$MI_TMP/ov.json")"
assert_eq "override reason"                "meta-plugin-issue" "$(jq -r '.dismissed["review-reject-bypassed"].reason' "$MI_TMP/ov.json")"
assert_eq "override dismissed_by"          "retrospective-weekly"    "$(jq -r '.dismissed["review-reject-bypassed"].dismissed_by' "$MI_TMP/ov.json")"
# existing-issue path
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '{"number":99,"url":"https://github.com/acme/example-repo/issues/99"}' ;;
  *"issue comment"*) echo 'commented' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
URL2="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag t-existing --slug t-existing --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov.json" 2>/dev/null)"
assert_eq "meta-issue reuses existing URL" "https://github.com/acme/example-repo/issues/99" "$URL2"
rm -rf "$MI_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "render-report.sh / open-state-pr.sh / post-status.sh"
# ────────────────────────────────────────────────────────────────────────────
( . "$LIB/render-report.sh"
  SUM='{"prs_scanned":8,"clean_count":3,"analyzed_count":5,"intervention_prs":[{"number":901,"tag":"implement-review-miss"}],"meta_issues":[{"tag":"review-reject-bypassed","url":"https://x/issues/9"}],"cooldown_skipped":["doc-inventory-inaccuracy"],"blockers":[],"state_pr":900}'
  REPORT="$(devflow_render_report "$SUM")"
  assert_eq "report has marker"        "true" "$(echo "$REPORT" | head -1 | grep -qF '<!-- devflow:audit-report -->' && echo true || echo false)"
  assert_eq "report shows prs_scanned"  "true" "$(echo "$REPORT" | grep -q '8' && echo true || echo false)"
  assert_eq "report lists PR 901"       "true" "$(echo "$REPORT" | grep -q 'PR #901' && echo true || echo false)"
  assert_eq "report lists meta tag"     "true" "$(echo "$REPORT" | grep -q 'review-reject-bypassed' && echo true || echo false)"
  assert_eq "report lists cooldown tag" "true" "$(echo "$REPORT" | grep -q 'doc-inventory-inaccuracy' && echo true || echo false)"
  # #7c: omit the new sections when the keys aren't supplied
  assert_eq "no Analyzed section without data" "false" "$(echo "$REPORT" | grep -q '### Analyzed PRs' && echo true || echo false)"
  assert_eq "no Patterns section without data" "false" "$(echo "$REPORT" | grep -q '## Patterns this run' && echo true || echo false)"
  # #7c: render them when supplied
  SUM2='{"prs_scanned":2,"clean_count":0,"analyzed_count":2,"analyzed":[{"pr":771,"verdict":"imperfect","summary":"merged over an outstanding /review REJECT"},{"pr":789,"verdict":"imperfect","summary":"internal doc listed files that no longer match"}],"patterns":[{"tag":"merged-over-review-reject","slug":"merged-over-review-reject","occurrence_count":2,"status":"open","cooldown_active":false},{"tag":"old-pattern","slug":"old-pattern","occurrence_count":3,"status":"open","cooldown_active":true}],"intervention_prs":[],"meta_issues":[],"cooldown_skipped":["old-pattern"],"blockers":[],"state_pr":810}'
  REPORT2="$(devflow_render_report "$SUM2")"
  assert_eq "Analyzed section present"        "true" "$(echo "$REPORT2" | grep -q '### Analyzed PRs' && echo true || echo false)"
  assert_eq "Analyzed line for PR 771"        "true" "$(echo "$REPORT2" | grep -q '#771 — imperfect: merged over an outstanding' && echo true || echo false)"
  assert_eq "Patterns section present"        "true" "$(echo "$REPORT2" | grep -q '## Patterns this run' && echo true || echo false)"
  assert_eq "Patterns sorted by count desc"   "true" "$(echo "$REPORT2" | grep -A2 '## Patterns this run' | grep -q 'old-pattern.*3×' && echo true || echo false)"
  assert_eq "cooldown pattern annotated"      "true" "$(echo "$REPORT2" | grep -q 'old-pattern.*cooldown, skipped this run' && echo true || echo false)"
)
OSPR="$(bash "$LIB/open-state-pr.sh" --branch devflow/learnings-test --dry-run 2>/dev/null)"
assert_eq "open-state-pr dry-run echoes DRYRUN" "true" "$(echo "$OSPR" | grep -q 'DRYRUN' && echo true || echo false)"
assert_eq "open-state-pr dry-run mentions git push" "true" "$(echo "$OSPR" | grep -qi 'git push' && echo true || echo false)"
PSR="$(echo '<!-- devflow:audit-report -->' > /tmp/devflow-test-report.md; bash "$LIB/post-status.sh" --pr 900 --report-file /tmp/devflow-test-report.md --dry-run 2>/dev/null; rm -f /tmp/devflow-test-report.md)"
assert_eq "post-status dry-run echoes DRYRUN" "true" "$(echo "$PSR" | grep -q 'DRYRUN' && echo true || echo false)"

# ────────────────────────────────────────────────────────────────────────────
echo "dismiss-stale-rejections.sh"
# ────────────────────────────────────────────────────────────────────────────
DSR="$LIB/../scripts/dismiss-stale-rejections.sh"

( bash "$DSR" >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "no args → exit 2" "2" "$DSR_RC"

# Security-critical: the review-selection filter must dismiss ONLY open
# Devflow-report reviews — never a human --request-changes (id 2), an
# already-dismissed one (id 3), or a null-body row (id 4).
DSR_SEL="$(printf '%s' '[
 {"id":1,"state":"CHANGES_REQUESTED","body":"# Review Report\n## Verdict: REJECT"},
 {"id":2,"state":"CHANGES_REQUESTED","body":"please fix the typo"},
 {"id":3,"state":"DISMISSED","body":"# Review Report\n## Verdict: REJECT"},
 {"id":4,"state":"CHANGES_REQUESTED","body":null}
]' | jq -r '.[] | select(.state=="CHANGES_REQUESTED" and ((.body // "") | startswith("# Review Report"))) | .id' | tr '\n' ',')"
assert_eq "filter selects only open Devflow-report rejects" "1," "$DSR_SEL"

DSR_STUB="/tmp/devflow-gh-stub-dsr.$$.sh"
cat > "$DSR_STUB" <<'EOS'
#!/usr/bin/env bash
# dismissals URLs also contain "/reviews" — match the more specific arm
# first, and give every arm a deterministic exit status.
case "$*" in
  *"dismissals"*)         [ "${DSR_STUB_PUT_RC:-0}" = 0 ] || { echo "HTTP 422" >&2; exit 1; }; exit 0 ;;
  *"repo view"*)          echo "o/r"; exit 0 ;;
  *"pulls/"*"/reviews"*)  if [ -n "${DSR_STUB_IDS:-}" ]; then echo "$DSR_STUB_IDS"; fi; exit 0 ;;
esac
exit 0
EOS
chmod +x "$DSR_STUB"

( DSR_STUB_IDS="" DEVFLOW_GH="$DSR_STUB" bash "$DSR" 123 o/r >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "empty selection → exit 0 no-op" "0" "$DSR_RC"

( DSR_STUB_IDS="77" DSR_STUB_PUT_RC=0 DEVFLOW_GH="$DSR_STUB" bash "$DSR" 123 o/r >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "successful dismissal → exit 0" "0" "$DSR_RC"

( DSR_STUB_IDS="77" DSR_STUB_PUT_RC=1 DEVFLOW_GH="$DSR_STUB" bash "$DSR" 123 o/r >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "dismissal failure → exit 1" "1" "$DSR_RC"
rm -f "$DSR_STUB"

# ────────────────────────────────────────────────────────────────────────────
echo "resolve-implement-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# The implement trigger runs the action in AGENT mode (explicit prompt), which
# executes for ANY actor — so this resolver is the cost/authorization gate AND
# the issue-number resolver. Tests stub `gh` for the collaborator-permission
# call; the allowed-bot path never reaches `gh`.
RIT="$LIB/../scripts/resolve-implement-trigger.sh"

# Inline gh stub: returns whatever STUB_PERM says for a collaborator-permission
# query (the script passes --jq '.permission'; like gh-stub.sh we ignore --jq
# and emit the already-extracted value), empty otherwise.
RIT_STUB_DIR="$(mktemp -d)"
cat > "$RIT_STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# STUB_ERR (to stderr) + STUB_RC let a test simulate gh failures (transient or
# 404); default is a clean success echoing STUB_PERM.
case "$*" in
  *"collaborators/"*"/permission"*)
    [ -n "${STUB_ERR:-}" ] && echo "$STUB_ERR" >&2
    [ "${STUB_RC:-0}" != 0 ] && exit "${STUB_RC}"
    echo "${STUB_PERM:-none}" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$RIT_STUB_DIR/gh"

# 1. Allowed bot + label event → run on the labelled issue. `foo[bot]` actor
#    must match the bare `foo` in allowed_bots. No gh call on this path.
OUT="$(ACTOR='foo[bot]' ALLOWED_BOTS='foo,bar' REPO='acme/x' \
  IS_LABEL_EVENT='true' TRIGGER_TEXT='' CONTEXT_NUMBER='42' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: allowed bot, label event → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: allowed bot, label event → number" \
  "number=42" "$(echo "$OUT" | grep '^number=')"

# 2. Write collaborator + explicit number in comment → run on that number.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='write' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: write collaborator, explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: explicit number beats context" \
  "number=7" "$(echo "$OUT" | grep '^number=')"

# 3. Non-collaborator (gh → 'none') → blocked, no number.
OUT="$(ACTOR='stranger' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='none' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: non-collaborator → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: non-collaborator → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"

# 4. Authorized but NO number anywhere → blocked (can't implement nothing).
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement please' CONTEXT_NUMBER='' \
  STUB_PERM='admin' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: no resolvable number → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 5. Authorized, no explicit number but a context issue → fall back to context.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement' CONTEXT_NUMBER='5' \
  STUB_PERM='maintain' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: fallback to context number" \
  "number=5" "$(echo "$OUT" | grep '^number=')"

# 6. Transient collaborator-API failure (non-404) → fails CLOSED with a
#    transient-specific diagnostic, NOT mislabelled as "not a collaborator".
#    RESOLVE_RETRY_DELAY=0 keeps the retry instant.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RC='1' STUB_ERR='gh: Internal Server Error (HTTP 500)' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT" 2>"$RIT_STUB_DIR/err")"
assert_eq "rit: transient API error → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: transient API error → honest diagnostic" \
  "1" "$(grep -c 'transient collaborator-API error' "$RIT_STUB_DIR/err")"

# 7. Genuine 404 (not a collaborator) → fails closed as before, no retry stall.
OUT="$(ACTOR='stranger' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RC='1' STUB_ERR='gh: Not Found (HTTP 404)' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT" 2>"$RIT_STUB_DIR/err")"
assert_eq "rit: 404 non-collaborator → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: 404 treated as non-collaborator, not transient" \
  "1" "$(grep -c 'is not an allowed bot or write/admin collaborator' "$RIT_STUB_DIR/err")"

rm -rf "$RIT_STUB_DIR"

# Tally the shell assertions from the results file (authoritative — includes the
# subshell blocks). The python section below adds its own counts on top.
PASS=$(grep -c '^PASS$' "$RESULTS_FILE" || true)
FAIL=$(grep -c '^FAIL$' "$RESULTS_FILE" || true)

# ────────────────────────────────────────────────────────────────────────────
echo "python scripts (workpad._apply_mutations, parse_acs._is_post_merge)"
# ────────────────────────────────────────────────────────────────────────────
PY_OUT="$(python3 "$(dirname "$0")/test_python_scripts.py" 2>&1)"
PY_RC=$?
PY_SUMMARY="$(echo "$PY_OUT" | awk '/passed,/ { p=$1; f=$3 } END { print p" "f }')"
PY_PASS="$(echo "$PY_SUMMARY" | awk '{ print $1 }')"
PY_FAIL="$(echo "$PY_SUMMARY" | awk '{ print $2 }')"
[ -n "$PY_PASS" ] && PASS=$((PASS + PY_PASS))
if [ "$PY_RC" -eq 0 ] && [ -n "$PY_PASS" ]; then
  printf '  PASS  %s python assertions\n' "$PY_PASS"
else
  FAIL=$((FAIL + ${PY_FAIL:-1}))
  echo "$PY_OUT" | sed 's/^/    /'
fi

# ────────────────────────────────────────────────────────────────────────────
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
