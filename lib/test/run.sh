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

assert_eq "cg: present scalar"          "claude,example-bot" "$("$CG" .devflow.allowed_bots '' "$FIX")"
assert_eq "cg: nested int"              "2"                   "$("$CG" .devflow_retrospective.min_occurrences '' "$FIX")"
assert_eq "cg: array → comma-join"      "claude,example-bot" "$("$CG" .devflow_retrospective.watched_authors '' "$FIX")"
assert_eq "cg: leading dot optional"    "2"                   "$("$CG" devflow_retrospective.min_occurrences '' "$FIX")"
assert_eq "cg: missing key → default"   "fallback"           "$("$CG" .a.b.c fallback "$FIX")"
assert_eq "cg: descend into scalar → default" "dfl"          "$("$CG" .devflow.allowed_bots.nope dfl "$FIX")"
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
echo "devflow_review_and_fix.max_iterations (schema + resolution)"
# ────────────────────────────────────────────────────────────────────────────
# The /devflow:review-and-fix fix-loop cap is read from config via config-get.sh
# (default 5) and then clamped INLINE in skills/review-and-fix/SKILL.md: a value
# below 1 → floor 1, a non-integer/empty/unparseable value (or a resolver failure)
# → 5, with no upper bound. The clamp itself is prompt bash (not a script — AC3
# mandates the SKILL read directly via config-get.sh), so we pin (a) the
# schema/example contract, (b) the resolver read behavior that feeds the clamp,
# and (c) the clamp logic via a function kept byte-aligned with the SKILL block.
MAXI_SCHEMA="$LIB/../.devflow/config.schema.json"
MAXI_EXAMPLE="$LIB/../.devflow/config.example.json"
MAXI_PROP='.properties.devflow_review_and_fix.properties.max_iterations'
assert_eq "max_iterations: schema type is integer" "integer" \
  "$(jq -r "$MAXI_PROP.type" "$MAXI_SCHEMA")"
assert_eq "max_iterations: schema minimum is 1" "1" \
  "$(jq -r "$MAXI_PROP.minimum" "$MAXI_SCHEMA")"
assert_eq "max_iterations: schema default is 5" "5" \
  "$(jq -r "$MAXI_PROP.default" "$MAXI_SCHEMA")"
assert_eq "max_iterations: schema has a non-empty description" "yes" \
  "$(jq -e "$MAXI_PROP.description | type == \"string\" and (length > 0)" "$MAXI_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "max_iterations: example value matches schema default" \
  "$(jq -r "$MAXI_PROP.default" "$MAXI_SCHEMA")" \
  "$(jq -r '.devflow_review_and_fix.max_iterations' "$MAXI_EXAMPLE")"

# Resolver-read behavior (the part the SKILL invokes; the clamp is downstream).
MAXI_CFG="$(mktemp)"
printf '%s' '{"devflow_review_and_fix":{"max_iterations":9}}' > "$MAXI_CFG"
assert_eq "max_iterations: configured integer read back verbatim" "9" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
# Key absent → resolver emits the default 5 (the no-config / unset case; AC: default 5).
printf '%s' '{"devflow_review_and_fix":{}}' > "$MAXI_CFG"
assert_eq "max_iterations: unset key → resolver default 5" "5" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
assert_eq "max_iterations: missing config file → resolver default 5" "5" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 /no/such/config.json)"
# A below-floor value (0) and a non-integer ("abc") are passed through verbatim by
# the resolver — the SKILL's inline clamp turns these into 1 and 5 respectively.
printf '%s' '{"devflow_review_and_fix":{"max_iterations":0}}' > "$MAXI_CFG"
assert_eq "max_iterations: below-floor value passed through to clamp (0)" "0" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
printf '%s' '{"devflow_review_and_fix":{"max_iterations":"abc"}}' > "$MAXI_CFG"
assert_eq "max_iterations: non-integer value passed through to clamp (abc)" "abc" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
rm -f "$MAXI_CFG"

# The SKILL's inline clamp, applied to the resolver output above. Mirrors the exact
# logic in skills/review-and-fix/SKILL.md so the floor/fallback/no-upper-bound ACs
# are exercised, not just asserted in prose. Keep byte-aligned with the SKILL block.
maxi_clamp() {
  local v="$1" rc="${2:-0}"
  if [ "$rc" -ne 0 ] || ! printf '%s' "$v" | grep -Eq '^-?[0-9]+$'; then
    printf '5\n'
  elif [ "$v" -lt 1 ]; then
    printf '1\n'
  else
    printf '%s\n' "$v"
  fi
}
assert_eq "max_iterations clamp: valid value honored"          "9"  "$(maxi_clamp 9)"
assert_eq "max_iterations clamp: large value honored (no cap)"  "42" "$(maxi_clamp 42)"
assert_eq "max_iterations clamp: 0 → floor 1"                  "1"  "$(maxi_clamp 0)"
assert_eq "max_iterations clamp: negative → floor 1"           "1"  "$(maxi_clamp -3)"
assert_eq "max_iterations clamp: non-integer → 5"              "5"  "$(maxi_clamp abc)"
assert_eq "max_iterations clamp: float → 5"                    "5"  "$(maxi_clamp 2.5)"
assert_eq "max_iterations clamp: empty → 5"                    "5"  "$(maxi_clamp '')"
assert_eq "max_iterations clamp: resolver failure (rc≠0) → 5"  "5"  "$(maxi_clamp '' 2)"

# Drift guard: maxi_clamp above is a hand-maintained copy of the SKILL's inline
# clamp, so the clamp assertions would keep passing even if the *shipped* clamp in
# SKILL.md were edited. Pin the load-bearing tokens in the real SKILL so a change to
# the regex (negative-aware), the below-1 floor, or the default-5 fallback fails here
# instead of silently passing against the copy.
MAXI_SKILL="$LIB/../skills/review-and-fix/SKILL.md"
assert_eq "max_iterations clamp: SKILL keeps the negative-aware integer regex" "yes" \
  "$(grep -qF "'^-?[0-9]+\$'" "$MAXI_SKILL" && echo yes || echo no)"
assert_eq "max_iterations clamp: SKILL keeps the below-1 floor" "yes" \
  "$(grep -qF '"$MAX_ITERS" -lt 1' "$MAXI_SKILL" && echo yes || echo no)"
assert_eq "max_iterations clamp: SKILL keeps the default-5 fallback" "yes" \
  "$(grep -qF 'MAX_ITERS=5' "$MAXI_SKILL" && echo yes || echo no)"

# Drift guard: the Phase 2.3 sweep list lives in three places that must stay in
# sync — the sweep body in implement/SKILL.md, the "Sweep selection" always-run
# index in the same file, and the rationale table in docs/implement-skill.md. The
# error-handling & silent-failure sweep (2.3.6) front-loads the Phase 3.3
# silent-failure-hunter agent; if any of the three loses it the catch reverts to
# the contingent, inconsistent homing the baseline showed. Pin all three so a
# half-applied removal fails here instead of silently shipping.
IMPL_SKILL="$LIB/../skills/implement/SKILL.md"
IMPL_DOC="$LIB/../docs/implement-skill.md"
assert_eq "sweep 2.3.6: implement SKILL keeps the sweep body" "yes" \
  "$(grep -qF '#### 2.3.6 Error-handling & silent-failure sweep' "$IMPL_SKILL" && echo yes || echo no)"
assert_eq "sweep 2.3.6: implement SKILL lists it in the always-run index" "yes" \
  "$(grep -qF '**2.3.6** (error-handling & silent-failure)' "$IMPL_SKILL" && echo yes || echo no)"
assert_eq "sweep 2.3.6: docs/implement-skill.md keeps the rationale table row" "yes" \
  "$(grep -qF '| 2.3.6 Error-handling & silent-failure |' "$IMPL_DOC" && echo yes || echo no)"
# Heading/index/table pins above catch a half-applied *removal* but not a semantic
# gutting that leaves the heading while deleting the sweep's load-bearing steps.
# Pin one step token unique to the 2.3.6 procedure (the false-success rule) so a
# reviewer who guts the steps but keeps the heading still trips the suite.
assert_eq "sweep 2.3.6: implement SKILL keeps the false-success step rule" "yes" \
  "$(grep -qF "never prints success for work that didn't happen" "$IMPL_SKILL" && echo yes || echo no)"

# Drift guard: the base_branch read in implement/SKILL.md Phase 1.4 is the skill's
# one piece of load-bearing inline bash — like the max_iterations clamp above, the
# tokens it relies on can be silently broken by a SKILL edit (drop the `|| BASE=""`
# and `git fetch origin ""` runs; drop the fetch guard and a bad base fails with a
# bare git error instead of an attributable DevFlow breadcrumb). Pin the tokens so
# a refactor of the block fails here rather than shipping a silent regression.
assert_eq "base_branch read: SKILL reads via config-get with the main default" "yes" \
  "$(grep -qF 'config-get.sh .base_branch main' "$IMPL_SKILL" && echo yes || echo no)"
assert_eq "base_branch read: SKILL guards the empty read" "yes" \
  "$(grep -qF '[ -n "$BASE" ]' "$IMPL_SKILL" && echo yes || echo no)"
assert_eq "base_branch read: SKILL fetches origin/\$BASE (not hard-coded main)" "yes" \
  "$(grep -qF 'git fetch origin "$BASE"' "$IMPL_SKILL" && echo yes || echo no)"
assert_eq "base_branch read: SKILL checks out origin/\$BASE" "yes" \
  "$(grep -qF 'git checkout -b "$BRANCH" "origin/$BASE"' "$IMPL_SKILL" && echo yes || echo no)"
assert_eq "base_branch read: SKILL keeps the attributable fetch-failure breadcrumb" "yes" \
  "$(grep -qF 'could not fetch base branch' "$IMPL_SKILL" && echo yes || echo no)"

# Behavioral coverage for the base_branch read+guard (token pins above catch a
# refactor that DROPS a token, but not a semantic regression in config-get's
# soft/hard contract that the guard depends on). Mirrors the max_iterations
# resolver+clamp pattern: exercise config-get's real exit behavior, then the
# SKILL's inline guard logic against it. Keep byte-aligned with the SKILL block.
BB_CFG="$(mktemp)"
printf '%s' '{"base_branch":"develop"}' > "$BB_CFG"
assert_eq "base_branch: configured value read back verbatim" "develop" \
  "$("$CG" .base_branch main "$BB_CFG")"
printf '%s' '{"devflow":{"effort":"high"}}' > "$BB_CFG"
assert_eq "base_branch: absent key → resolver soft-defaults to main (exit 0)" "main" \
  "$("$CG" .base_branch main "$BB_CFG")"
assert_eq "base_branch: missing config file → resolver soft-defaults to main (exit 0)" "main" \
  "$("$CG" .base_branch main /no/such/config.json)"
# Hard path: a malformed config must exit NON-ZERO with EMPTY stdout (the default is
# NOT applied) — this is the exact contract the inline guard relies on. A regression
# that made config-get emit `main` here would silently mask a malformed-config repo
# onto main; this assertion fails loudly if that contract ever drifts.
printf '%s' '{bad json' > "$BB_CFG"
BB_OUT="$("$CG" .base_branch main "$BB_CFG" 2>/dev/null)"; BB_RC=$?
assert_eq "base_branch: malformed config → resolver exits non-zero, empty stdout" "nonzero-empty" \
  "$([ "$BB_RC" -ne 0 ] && [ -z "$BB_OUT" ] && echo nonzero-empty || echo "rc=$BB_RC out='$BB_OUT'")"
rm -f "$BB_CFG"

# The SKILL's inline empty-read guard (Phase 1.4): an empty OR failed read → 'main'.
# Mirrors `BASE=$(config-get.sh …) || BASE=""; [ -n "$BASE" ] || BASE=main` so the
# fallback is exercised as behavior, not just asserted as text.
base_guard() {
  local v="$1" rc="${2:-0}"
  { [ "$rc" -eq 0 ] && [ -n "$v" ]; } && { printf '%s\n' "$v"; return; }
  printf 'main\n'
}
assert_eq "base_branch guard: configured value honored"            "develop" "$(base_guard develop)"
assert_eq "base_branch guard: empty read (rc 0) → main"            "main"    "$(base_guard '')"
assert_eq "base_branch guard: hard-failure read (rc≠0, empty) → main" "main" "$(base_guard '' 2)"

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

# 2. Existing config.json + .gitignore → the user's value is NEVER clobbered
#    (missing keys are backfilled — see block 5); schema still refreshed.
SC_KEEP="$(mktemp -d)"
mkdir -p "$SC_KEEP/.devflow"
printf '{"sentinel":true}' > "$SC_KEEP/.devflow/config.json"
printf 'STALE' > "$SC_KEEP/.devflow/config.schema.json"
printf 'CUSTOM-IGNORE\n' > "$SC_KEEP/.devflow/.gitignore"
bash "$SC" "$SC_KEEP" >/dev/null 2>&1
assert_eq "scaffold: existing custom value preserved through backfill" \
  "true" "$(jq -r '.sentinel' "$SC_KEEP/.devflow/config.json")"
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

# 5. Config-key backfill on an existing config: a recursive deep-merge adds keys
#    newly introduced in the example (at any depth) while preserving the user's
#    values and arrays. No language markers in these throwaway dirs, so the
#    detect step is a no-op and only the backfill is under test.
SC_BF="$(mktemp -d)"; mkdir -p "$SC_BF/.devflow"
# An old config predating devflow_runner.provision_env: a custom top-level value,
# a custom nested value, and a user-tuned array we must not touch.
printf '%s' '{"base_branch":"release","devflow_runner":{"effort":"high"},"devflow":{"allowed_tools":["Bash(make:*)","Bash(npm:*)"]}}' \
  > "$SC_BF/.devflow/config.json"
# Capture stdout so we can also assert the backfill log line the /devflow:init
# skill (skills/init/SKILL.md) keys its "After running" guidance off of.
SC_BF_OUT="$(bash "$SC" "$SC_BF" 2>&1)"
assert_eq "scaffold-backfill: nested missing key added (devflow_runner.provision_env)" \
  "false" "$(jq -r '.devflow_runner.provision_env' "$SC_BF/.devflow/config.json")"
assert_eq "scaffold-backfill: top-level missing key added (claude_model)" \
  "claude-opus-4-8" "$(jq -r '.claude_model' "$SC_BF/.devflow/config.json")"
assert_eq "scaffold-backfill: existing top-level value preserved (base_branch)" \
  "release" "$(jq -r '.base_branch' "$SC_BF/.devflow/config.json")"
assert_eq "scaffold-backfill: existing nested value preserved (devflow_runner.effort)" \
  "high" "$(jq -r '.devflow_runner.effort' "$SC_BF/.devflow/config.json")"
# jq `*` replaces arrays with the right operand (the user's), never merging or
# deduping — so the user's array survives with its exact elements and order
# (read back via `jq -c`, which normalizes whitespace but not contents).
assert_eq "scaffold-backfill: existing array left unchanged (allowed_tools)" \
  '["Bash(make:*)","Bash(npm:*)"]' \
  "$(jq -c '.devflow.allowed_tools' "$SC_BF/.devflow/config.json")"
# The documented log line fires when a backfill actually happens.
assert_eq "scaffold-backfill: backfill emits the documented log line" "yes" \
  "$(printf '%s' "$SC_BF_OUT" | grep -q 'backfilled newly-added keys' && echo yes || echo no)"

# 5b. A config already holding every example key is a no-op: byte-for-byte
#     identical afterwards (the merge changed nothing, so the file isn't rewritten)
#     and the backfill log line is NOT emitted.
SC_NOOP="$(mktemp -d)"; mkdir -p "$SC_NOOP/.devflow"
cp "$TPL_DIR/config.example.json" "$SC_NOOP/.devflow/config.json"
SC_NOOP_BEFORE="$(cat "$SC_NOOP/.devflow/config.json")"
SC_NOOP_OUT="$(bash "$SC" "$SC_NOOP" 2>&1)"
assert_eq "scaffold-backfill: complete config is a byte-identical no-op" \
  "$SC_NOOP_BEFORE" "$(cat "$SC_NOOP/.devflow/config.json")"
assert_eq "scaffold-backfill: no-op does NOT emit the backfill log line" "no" \
  "$(printf '%s' "$SC_NOOP_OUT" | grep -q 'backfilled newly-added keys' && echo yes || echo no)"
# The shipped example pins Sonnet 4.6 (no Haiku override), so a fresh scaffold of
# it must never emit the Haiku effort-cleanup log line — locks the clean path so
# a regression that re-pins Haiku-with-effort in the example is caught.
assert_eq "scaffold-migration: clean shipped example emits no Haiku cleanup log line" "no" \
  "$(printf '%s' "$SC_NOOP_OUT" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"

# 5c. jq unavailable → backfill skipped, scaffold still succeeds and leaves the
#     config untouched. Run under a PATH that resolves the coreutils the scaffold
#     needs but NOT jq, so `command -v jq` fails exactly as on a host without jq.
#     The symlink set below must track every external command scaffold-config.sh
#     (and its detect-project-tools.sh callee) reaches on the jq-absent path; git
#     is intentionally absent because TARGET_ROOT is passed explicitly ($1), and
#     mv/find/grep are not reached once `command -v jq` short-circuits.
SC_NOJQ="$(mktemp -d)"; mkdir -p "$SC_NOJQ/.devflow"
printf '%s' '{"sentinel":true}' > "$SC_NOJQ/.devflow/config.json"
NOJQ_BIN="$(mktemp -d)"
for b in bash dirname mkdir cp rm cat printf find grep diff mktemp; do
  src="$(command -v "$b")" && ln -s "$src" "$NOJQ_BIN/$b"
done
BASH_BIN="$(command -v bash)"
PATH="$NOJQ_BIN" "$BASH_BIN" "$SC" "$SC_NOJQ" >/dev/null 2>&1
assert_eq "scaffold-backfill: jq unavailable → scaffold exits 0 (best-effort)" \
  "0" "$?"
assert_eq "scaffold-backfill: jq unavailable → config left as-is (no backfill)" \
  '{"sentinel":true}' "$(cat "$SC_NOJQ/.devflow/config.json")"

# 5d. Malformed (invalid-JSON) existing config → backfill skipped, scaffold still
#     succeeds, the malformed bytes are left untouched (no clobber/truncation),
#     and the schema is still refreshed (proving the scaffold proceeded past the
#     skip). Guards the `jq -e .` validity branch.
SC_BAD="$(mktemp -d)"; mkdir -p "$SC_BAD/.devflow"
printf '%s' '{ not valid json' > "$SC_BAD/.devflow/config.json"
bash "$SC" "$SC_BAD" >/dev/null 2>&1
assert_eq "scaffold-backfill: malformed config → scaffold exits 0 (best-effort)" \
  "0" "$?"
assert_eq "scaffold-backfill: malformed config left untouched (no clobber)" \
  '{ not valid json' "$(cat "$SC_BAD/.devflow/config.json")"
assert_eq "scaffold-backfill: malformed config → schema still refreshed" \
  "$(cat "$TPL_DIR/config.schema.json")" "$(cat "$SC_BAD/.devflow/config.schema.json")"

rm -rf "$SC_FRESH" "$SC_KEEP" "$SC_NOTPL" "$SC_NOTPL_TGT" "$SC_BF" "$SC_NOOP" "$SC_NOJQ" "$NOJQ_BIN" "$SC_BAD"

# 6. Haiku effort-cleanup migration on an EXISTING config: scaffold-config.sh
#    strips `effort` from any agent_overrides entry whose model is a Haiku id.
#    An earlier release removed that effort key from the example, but the add-only
#    backfill can never propagate a removal to a pre-existing config, so the
#    dedicated cleanup is what repairs an adopter's stale HTTP-400 combo. Mirrors
#    the SC_BF inline-mktemp pattern; no language markers, so detect is a no-op.
SC_MIG="$(mktemp -d)"; mkdir -p "$SC_MIG/.devflow"
# A legacy config: Haiku deduper carrying the HTTP-400 effort key, a SECOND
# Haiku-pinned entry on a different agent (proving the cleanup generalizes to
# any Haiku override, not just the deduper — a regression that hard-coded the
# deduper key would otherwise pass green), plus a non-Haiku override whose
# effort must be left untouched.
printf '%s' '{"devflow_review":{"agent_overrides":{"default":{"effort":"medium"},"devflow:checklist-deduper":{"model":"claude-haiku-4-5-20251001","effort":"low"},"devflow:checklist-generator":{"model":"claude-haiku-4-5-20251001","effort":"high"},"pr-review-toolkit:code-reviewer":{"model":"claude-opus-4-8","effort":"high"}}}}' \
  > "$SC_MIG/.devflow/config.json"
SC_MIG_OUT="$(bash "$SC" "$SC_MIG" 2>&1)"
assert_eq "scaffold-migration: Haiku deduper effort stripped" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] | has("effort")' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: Haiku deduper model preserved" \
  "claude-haiku-4-5-20251001" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].model' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: second Haiku-pinned entry (non-deduper) also stripped" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-generator"] | has("effort")' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: non-Haiku override effort left untouched" \
  "high" "$(jq -r '.devflow_review.agent_overrides["pr-review-toolkit:code-reviewer"].effort' "$SC_MIG/.devflow/config.json")"
# The model-less `default` entry must survive: `(.value.model // "")` yields ""
# which fails the Haiku predicate, so its effort is kept. Asserted on the FIRST
# run directly (not just via the idempotent no-op below, which would pass even
# if both runs stripped it identically), so a regression dropping the model
# guard is caught loudly.
assert_eq "scaffold-migration: model-less default override effort left untouched" \
  "medium" "$(jq -r '.devflow_review.agent_overrides.default.effort' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: cleanup emits the documented log line" "yes" \
  "$(printf '%s' "$SC_MIG_OUT" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"
# Second run is a no-churn no-op: config already clean → byte-identical and the
# cleanup log line is NOT re-emitted.
SC_MIG_BEFORE="$(cat "$SC_MIG/.devflow/config.json")"
SC_MIG_OUT2="$(bash "$SC" "$SC_MIG" 2>&1)"
assert_eq "scaffold-migration: second run is a byte-identical no-op" \
  "$SC_MIG_BEFORE" "$(cat "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: clean config does NOT re-emit the cleanup log line" "no" \
  "$(printf '%s' "$SC_MIG_OUT2" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"
rm -rf "$SC_MIG"

# 6b. jq unavailable during the Haiku effort-cleanup: a config that DOES carry a
#     stale Haiku+effort combo must be LEFT UNTOUCHED (cleanup skipped, not
#     silently "nothing to do"), and the skip breadcrumb must fire. The SC_NOJQ
#     case above uses a non-Haiku config, so it cannot tell "correctly skipped"
#     from "no work"; this fixture closes that gap. Same PATH-without-jq trick.
SC_MIG_NOJQ="$(mktemp -d)"; mkdir -p "$SC_MIG_NOJQ/.devflow"
printf '%s' '{"devflow_review":{"agent_overrides":{"devflow:checklist-deduper":{"model":"claude-haiku-4-5-20251001","effort":"low"}}}}' \
  > "$SC_MIG_NOJQ/.devflow/config.json"
MIG_NOJQ_BIN="$(mktemp -d)"
for b in bash dirname mkdir cp rm cat printf find grep diff mktemp; do
  src="$(command -v "$b")" && ln -s "$src" "$MIG_NOJQ_BIN/$b"
done
MIG_BASH_BIN="$(command -v bash)"
SC_MIG_NOJQ_OUT="$(PATH="$MIG_NOJQ_BIN" "$MIG_BASH_BIN" "$SC" "$SC_MIG_NOJQ" 2>&1)"
# Read back with the test's normal (jq-present) PATH; only the scaffold RAN jq-less.
assert_eq "scaffold-migration: jq unavailable → Haiku+effort combo left untouched (skipped, not a no-op)" \
  "low" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].effort' "$SC_MIG_NOJQ/.devflow/config.json")"
assert_eq "scaffold-migration: jq unavailable → emits the cleanup-skipped breadcrumb" "yes" \
  "$(printf '%s' "$SC_MIG_NOJQ_OUT" | grep -q 'skipping Haiku effort-cleanup' && echo yes || echo no)"
rm -rf "$SC_MIG_NOJQ" "$MIG_NOJQ_BIN"

# 6c. agent_overrides hand-corrupted to a non-object (array): the cleanup filter
#     no-ops via its `else .` arm, but the anti-silent-failure breadcrumb must
#     fire so the silence is not an ambiguous "nothing to do". The backfill leaves
#     the array in place (jq `*` lets the right operand win on a type mismatch).
SC_AO_BAD="$(mktemp -d)"; mkdir -p "$SC_AO_BAD/.devflow"
printf '%s' '{"devflow_review":{"agent_overrides":["oops"]}}' > "$SC_AO_BAD/.devflow/config.json"
SC_AO_BAD_OUT="$(bash "$SC" "$SC_AO_BAD" 2>&1)"
assert_eq "scaffold-migration: non-object agent_overrides emits the skip breadcrumb" "yes" \
  "$(printf '%s' "$SC_AO_BAD_OUT" | grep -q 'agent_overrides is present but not an object' && echo yes || echo no)"
rm -rf "$SC_AO_BAD"

# 6c-bis. devflow_review ITSELF is a non-object (a string). It is valid JSON (so it
#     passes the jq -e . gate), but `.devflow_review.agent_overrides` then ERRORS
#     rather than yielding null. The breadcrumb probe must surface that as its own
#     specific "could not inspect ... (jq error ...)" line — not fold the error into
#     "null" and stay silent (the silent-failure-hunter gap). The scaffold still
#     exits 0 (best-effort) and leaves the malformed value untouched.
SC_DR_BAD="$(mktemp -d)"; mkdir -p "$SC_DR_BAD/.devflow"
printf '%s' '{"devflow_review":"oops"}' > "$SC_DR_BAD/.devflow/config.json"
SC_DR_BAD_OUT="$(bash "$SC" "$SC_DR_BAD" 2>&1)"; SC_DR_BAD_RC=$?
assert_eq "scaffold-migration: non-object devflow_review → scaffold still exits 0 (best-effort)" \
  "0" "$SC_DR_BAD_RC"
assert_eq "scaffold-migration: non-object devflow_review emits the probe-error breadcrumb (not swallowed to 'null')" "yes" \
  "$(printf '%s' "$SC_DR_BAD_OUT" | grep -q 'could not inspect .devflow_review.agent_overrides' && echo yes || echo no)"
# A scalar devflow_review must not DETONATE the backfill or cleanup jq into a
# misdirected generic failure. The backfill still merges the other top-level keys
# (a non-object devflow_review short-circuits the graft-guard's `if` to `else .`),
# and the cleanup no-ops cleanly — so neither the "merge failed" nor the "cleanup
# failed" generic breadcrumb fires; only the accurate probe breadcrumb above does.
assert_eq "scaffold-migration: non-object devflow_review does NOT emit the misdirected backfill 'merge failed'" "no" \
  "$(printf '%s' "$SC_DR_BAD_OUT" | grep -q 'config-key backfill merge failed' && echo yes || echo no)"
assert_eq "scaffold-migration: non-object devflow_review does NOT emit the misdirected 'cleanup failed'" "no" \
  "$(printf '%s' "$SC_DR_BAD_OUT" | grep -q 'Haiku effort-cleanup failed' && echo yes || echo no)"
rm -rf "$SC_DR_BAD"

# 6d. Graft guard: a config that re-pins the deduper to a Haiku id WITHOUT effort
#     must NOT gain an effort key from the example's Sonnet-4.6+effort deduper
#     default via the backfill deep-merge (Haiku rejects effort with HTTP 400; an
#     ungated graft would re-fire on every re-scaffold and churn against the
#     cleanup). Start from a COMPLETE example-derived config so the ONLY thing the
#     backfill could change is the grafted effort — making this a precise probe.
SC_GRAFT="$(mktemp -d)"; mkdir -p "$SC_GRAFT/.devflow"
jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] = {"model":"claude-haiku-4-5-20251001"}' \
  "$TPL_DIR/config.example.json" > "$SC_GRAFT/.devflow/config.json"
SC_GRAFT_BEFORE="$(cat "$SC_GRAFT/.devflow/config.json")"
SC_GRAFT_OUT="$(bash "$SC" "$SC_GRAFT" 2>&1)"
assert_eq "scaffold-graft-guard: backfill does NOT graft effort onto a Haiku deduper" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] | has("effort")' "$SC_GRAFT/.devflow/config.json")"
assert_eq "scaffold-graft-guard: Haiku deduper model preserved" \
  "claude-haiku-4-5-20251001" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].model' "$SC_GRAFT/.devflow/config.json")"
assert_eq "scaffold-graft-guard: re-scaffold is a byte-identical quiet no-op" \
  "$SC_GRAFT_BEFORE" "$(cat "$SC_GRAFT/.devflow/config.json")"
assert_eq "scaffold-graft-guard: quiet no-op emits neither backfill nor cleanup log" "yes" \
  "$(printf '%s' "$SC_GRAFT_OUT" | grep -qE "backfilled newly-added keys|removed unsupported 'effort'" && echo no || echo yes)"
rm -rf "$SC_GRAFT"

# 6e. Graft-guard PRESERVE branch: a user who pins the deduper to a Haiku id WITH
#     their OWN effort must have that effort PRESERVED by the backfill (the
#     graft-guard strips only a *grafted* effort, never the user's) and removed by
#     the dedicated CLEANUP instead. SC_MIG only asserts the end state (effort
#     gone), which cannot tell "graft-guard preserved + cleanup stripped" from a
#     regression where "graft-guard wrongly stripped + cleanup no-op" — both leave
#     effort absent. Discriminate via the CLEANUP log: it fires only if the effort
#     SURVIVED the backfill into the cleanup. Start from a COMPLETE example-derived
#     config so the backfill is otherwise a byte-identical no-op.
SC_PRESERVE="$(mktemp -d)"; mkdir -p "$SC_PRESERVE/.devflow"
jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] = {"model":"claude-haiku-4-5-20251001","effort":"low"}' \
  "$TPL_DIR/config.example.json" > "$SC_PRESERVE/.devflow/config.json"
SC_PRESERVE_OUT="$(bash "$SC" "$SC_PRESERVE" 2>&1)"
# The discriminator: the cleanup log fires ⇒ the user's effort survived the backfill
# (graft-guard left it alone) and the dedicated cleanup is what stripped it. A
# regression that strips a user's own effort in the backfill would make the backfill
# log fire and the cleanup a silent no-op — failing this assertion.
assert_eq "scaffold-graft-guard: user's OWN Haiku effort survives backfill and is stripped by the cleanup" \
  "yes" "$(printf '%s' "$SC_PRESERVE_OUT" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"
assert_eq "scaffold-graft-guard: preserve-branch sees no backfill rewrite (graft-guard touched nothing)" \
  "no" "$(printf '%s' "$SC_PRESERVE_OUT" | grep -q 'backfilled newly-added keys' && echo yes || echo no)"
assert_eq "scaffold-graft-guard: preserve-branch effort ultimately removed" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] | has("effort")' "$SC_PRESERVE/.devflow/config.json")"
assert_eq "scaffold-graft-guard: preserve-branch Haiku model kept through both passes" \
  "claude-haiku-4-5-20251001" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].model' "$SC_PRESERVE/.devflow/config.json")"
rm -rf "$SC_PRESERVE"

# 6f. Robustness: a non-string `model` on ONE agent_overrides entry must not
#     detonate the whole backfill/cleanup jq and leave sibling Haiku entries
#     un-repaired. Without the `(.value.model | strings)` guard, `startswith` on a
#     non-string model errors (rc=5), aborting the filter for ALL entries — so a
#     valid Haiku+effort sibling keeps its HTTP-400 combo and the only breadcrumb
#     is a misdirected generic "jq error". The guard makes a non-string model fall
#     through `else .` (unmatched) so siblings are still repaired. Fixture: a
#     complete example-derived config with a valid Haiku+effort entry AND a
#     non-string-model entry.
SC_BADMODEL="$(mktemp -d)"; mkdir -p "$SC_BADMODEL/.devflow"
jq '.devflow_review.agent_overrides["devflow:checklist-generator"] = {"model":"claude-haiku-4-5-20251001","effort":"high"}
    | .devflow_review.agent_overrides["devflow:checklist-verifier"] = {"model":{"oops":true},"effort":"low"}' \
  "$TPL_DIR/config.example.json" > "$SC_BADMODEL/.devflow/config.json"
SC_BADMODEL_OUT="$(bash "$SC" "$SC_BADMODEL" 2>&1)"; SC_BADMODEL_RC=$?
assert_eq "scaffold-robustness: non-string model entry does not abort the scaffold (exit 0)" \
  "0" "$SC_BADMODEL_RC"
assert_eq "scaffold-robustness: valid Haiku sibling still has its effort stripped despite a non-string-model entry" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-generator"] | has("effort")' "$SC_BADMODEL/.devflow/config.json")"
assert_eq "scaffold-robustness: the non-string-model entry is left untouched (unmatched, did not detonate the filter)" \
  "low" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-verifier"].effort' "$SC_BADMODEL/.devflow/config.json")"
rm -rf "$SC_BADMODEL"

# 6g. Unit-test the rewrite_config_if_changed helper in ISOLATION, sourced via the
#     library-only hook (DEVFLOW_SCAFFOLD_LIB_ONLY) so the helpers load without the
#     scaffold body running. This locks the two robustness arms the main flow's
#     validity gate keeps unreachable once it has passed: a normalization (jq)
#     failure must NOT phantom-rewrite, and a write (mv) failure must
#     log-and-continue. Run in a subshell so the helper's `set -euo pipefail` and
#     its log()/die() definitions never leak into the rest of the suite.
( export DEVFLOW_SCAFFOLD_LIB_ONLY=1
  # shellcheck disable=SC1090
  . "$SC"
  set +e +o pipefail
  # (a) cmpfail arm — the bug the helper exists to prevent: a left-hand (cfg)
  #     normalization failure must log the comparison-untrusted message and leave
  #     cfg untouched, NOT mv the candidate over it (the process-substitution
  #     phantom-rewrite trap).
  HU="$(mktemp -d)"
  printf '%s' 'not json' > "$HU/cfg.json"      # cfg fails jq --sort-keys
  printf '%s' '{"a":2}'  > "$HU/cand.json"      # cand is valid and differs
  HU_BEFORE="$(cat "$HU/cfg.json")"
  HU_OUT="$(rewrite_config_if_changed "$HU/cfg.json" "$HU/cand.json" "HELPERTEST-CHANGED" "HELPERTEST-CMPFAIL" 2>&1)"
  HU_RC=$?
  assert_eq "rewrite-helper: cmpfail arm returns 0 (does not abort the scaffold)" "0" "$HU_RC"
  assert_eq "rewrite-helper: cmpfail arm emits the comparison-untrusted message" "yes" \
    "$(printf '%s' "$HU_OUT" | grep -q 'HELPERTEST-CMPFAIL' && echo yes || echo no)"
  assert_eq "rewrite-helper: cmpfail arm does NOT phantom-rewrite (cfg bytes survive)" \
    "$HU_BEFORE" "$(cat "$HU/cfg.json")"
  assert_eq "rewrite-helper: cmpfail arm does NOT emit the changed message" "no" \
    "$(printf '%s' "$HU_OUT" | grep -q 'HELPERTEST-CHANGED' && echo yes || echo no)"
  rm -rf "$HU"

  # (b) happy path: two differing valid configs ARE rewritten, changed message fires.
  HU_OK="$(mktemp -d)"
  printf '%s' '{"a":1}' > "$HU_OK/cfg.json"
  printf '%s' '{"a":2}' > "$HU_OK/cand.json"
  HU_OK_OUT="$(rewrite_config_if_changed "$HU_OK/cfg.json" "$HU_OK/cand.json" "HELPERTEST-CHANGED" "HELPERTEST-CMPFAIL" 2>&1)"
  assert_eq "rewrite-helper: happy path rewrites the config (cand wins)" "2" \
    "$(jq -r '.a' "$HU_OK/cfg.json")"
  assert_eq "rewrite-helper: happy path emits the changed message" "yes" \
    "$(printf '%s' "$HU_OK_OUT" | grep -q 'HELPERTEST-CHANGED' && echo yes || echo no)"
  rm -rf "$HU_OK"

  # (c) mv-failure arm: a write failure must log-and-continue (return 0), leaving
  #     the original bytes — not abort under set -euo pipefail. Provoked by making
  #     cfg's directory unwritable, which only bites a non-root user; root bypasses
  #     permission bits, so skip there (CI runs non-root and exercises this).
  if [ "$(id -u)" -ne 0 ]; then
    HU_RO="$(mktemp -d)"
    printf '%s' '{"a":1}' > "$HU_RO/cfg.json"
    HU_CAND="$(mktemp)"
    printf '%s' '{"a":2}' > "$HU_CAND"
    HU_RO_BEFORE="$(cat "$HU_RO/cfg.json")"
    chmod a-w "$HU_RO"
    HU_RO_OUT="$(rewrite_config_if_changed "$HU_RO/cfg.json" "$HU_CAND" "HELPERTEST-CHANGED" "HELPERTEST-CMPFAIL" 2>&1)"
    HU_RO_RC=$?
    chmod u+w "$HU_RO"
    assert_eq "rewrite-helper: mv-failure arm returns 0 (logs-and-continues)" "0" "$HU_RO_RC"
    assert_eq "rewrite-helper: mv-failure arm emits the could-not-write message" "yes" \
      "$(printf '%s' "$HU_RO_OUT" | grep -q 'could not write' && echo yes || echo no)"
    assert_eq "rewrite-helper: mv-failure arm leaves the original bytes intact" \
      "$HU_RO_BEFORE" "$(cat "$HU_RO/cfg.json")"
    rm -rf "$HU_RO" "$HU_CAND"
  fi
)

# 6h. Positive jq-EXECUTION-failure path for the backfill arm: a CORRUPT
#     config.example.json next to a COPY of the scaffolder makes the backfill's
#     `jq -n --slurpfile ex ...` fail to PARSE the template (not merely be absent),
#     so the "merge failed (jq error)" arm fires for real — it previously had only
#     negative assertions. The existing valid config.json is left untouched and the
#     scaffold still exits 0 (best-effort). Mirrors the SC_NOTPL copy-the-script
#     layout so the template resolves next to the copy.
SC_JQERR="$(mktemp -d)"; mkdir -p "$SC_JQERR/scripts" "$SC_JQERR/.devflow"
cp "$SC" "$SC_JQERR/scripts/scaffold-config.sh"
printf '%s' '{ corrupt example'   > "$SC_JQERR/.devflow/config.example.json"
cp "$TPL_DIR/config.schema.json"    "$SC_JQERR/.devflow/config.schema.json"
SC_JQERR_TGT="$(mktemp -d)"; mkdir -p "$SC_JQERR_TGT/.devflow"
printf '%s' '{"sentinel":true}'    > "$SC_JQERR_TGT/.devflow/config.json"
SC_JQERR_OUT="$(bash "$SC_JQERR/scripts/scaffold-config.sh" "$SC_JQERR_TGT" 2>&1)"; SC_JQERR_RC=$?
assert_eq "scaffold-jqerr: corrupt example template → scaffold still exits 0 (best-effort)" \
  "0" "$SC_JQERR_RC"
assert_eq "scaffold-jqerr: corrupt example template → the backfill 'merge failed (jq error)' arm fires" "yes" \
  "$(printf '%s' "$SC_JQERR_OUT" | grep -q 'config-key backfill merge failed (jq error)' && echo yes || echo no)"
assert_eq "scaffold-jqerr: corrupt example template → existing config left untouched (no clobber)" \
  '{"sentinel":true}' "$(cat "$SC_JQERR_TGT/.devflow/config.json")"
rm -rf "$SC_JQERR" "$SC_JQERR_TGT"

# ────────────────────────────────────────────────────────────────────────────
echo "scaffold-config.sh: creates .devflow/prompt-extensions/ + an inert example"
# ────────────────────────────────────────────────────────────────────────────
# Scaffolding must create the consumer-owned prompt-extensions directory with a
# commented EXAMPLE file (issue #84, AC 9). The example must be INERT — named
# with a `.example` suffix so it is NOT a live `<skill>.md` that would inject
# itself into a real skill run.
SC="$LIB/../scripts/scaffold-config.sh"
SC_PE="$(mktemp -d)"
bash "$SC" "$SC_PE" >/dev/null 2>&1
assert_eq "scaffold-pe: .devflow/prompt-extensions/ created" "yes" \
  "$([ -d "$SC_PE/.devflow/prompt-extensions" ] && echo yes || echo no)"
assert_eq "scaffold-pe: commented example file created" "yes" \
  "$([ -f "$SC_PE/.devflow/prompt-extensions/create-issue.md.example" ] && echo yes || echo no)"
# The example carries explanatory comment text — verify it actually opens an
# HTML comment block (stronger than a bare non-empty check, which its name implies).
assert_eq "scaffold-pe: example file is a commented block" "yes" \
  "$(grep -qF '<!--' "$SC_PE/.devflow/prompt-extensions/create-issue.md.example" && echo yes || echo no)"
# Inert: no live `<skill>.md` is scaffolded (only the .example template), so the
# no-op path is the default until a consumer deliberately drops a real file. Use a
# glob + `[ -e ]` rather than spawning `ls` to test for existence; with nullglob
# off, an unmatched glob leaves the literal pattern in "$1", which `[ -e ]` rejects.
assert_eq "scaffold-pe: example is inert (no live <skill>.md present)" "no" \
  "$(set -- "$SC_PE/.devflow/prompt-extensions/"*.md; [ -e "$1" ] && echo yes || echo no)"
# Idempotent: a second run leaves the example byte-identical (guards the
# `if [ ! -d ]` create guard against re-writing on every run).
SC_PE_EX1="$(cat "$SC_PE/.devflow/prompt-extensions/create-issue.md.example")"
bash "$SC" "$SC_PE" >/dev/null 2>&1
assert_eq "scaffold-pe: idempotent re-run keeps example unchanged" \
  "$SC_PE_EX1" "$(cat "$SC_PE/.devflow/prompt-extensions/create-issue.md.example")"
rm -rf "$SC_PE"

# ────────────────────────────────────────────────────────────────────────────
echo "load-prompt-extension.sh (consumer prompt-extension reader)"
# ────────────────────────────────────────────────────────────────────────────
# The helper prints .devflow/prompt-extensions/<skill>.md verbatim (relative to
# CWD) when present, nothing otherwise; it validates the skill-name argument and
# refuses any value containing '/' or '..' before touching the filesystem.
# (issue #84, AC 1–5, AC 8.)
LPE="$LIB/../scripts/load-prompt-extension.sh"
LPE_DIR="$(mktemp -d)"
mkdir -p "$LPE_DIR/.devflow/prompt-extensions"

# AC 1: present → stdout equals the file, exit 0.
printf 'line one\nline two\n' > "$LPE_DIR/.devflow/prompt-extensions/implement.md"
LPE_OUT="$(cd "$LPE_DIR" && bash "$LPE" implement 2>/dev/null)"; LPE_RC=$?
assert_eq "lpe: present → verbatim stdout (newlines trimmed by \$())" \
  "$(printf 'line one\nline two')" "$LPE_OUT"
assert_eq "lpe: present → exit 0" "0" "$LPE_RC"

# AC 4: byte-for-byte verbatim incl. multi-byte UTF-8, NO trailing newline added
# when the file has none. cmp the helper's raw bytes against the source file.
printf 'café 日本語 🎉 no-trailing-newline' > "$LPE_DIR/.devflow/prompt-extensions/review.md"
( cd "$LPE_DIR" && bash "$LPE" review 2>/dev/null ) > "$LPE_DIR/out-utf8.bin"
assert_eq "lpe: UTF-8 verbatim, no trailing newline added (cmp byte-exact)" "yes" \
  "$(cmp -s "$LPE_DIR/.devflow/prompt-extensions/review.md" "$LPE_DIR/out-utf8.bin" && echo yes || echo no)"
# AC 4 (other direction): a file WITH a trailing newline round-trips unchanged.
printf 'has trailing newline\n' > "$LPE_DIR/.devflow/prompt-extensions/docs.md"
( cd "$LPE_DIR" && bash "$LPE" docs 2>/dev/null ) > "$LPE_DIR/out-nl.bin"
assert_eq "lpe: trailing-newline file round-trips byte-for-byte" "yes" \
  "$(cmp -s "$LPE_DIR/.devflow/prompt-extensions/docs.md" "$LPE_DIR/out-nl.bin" && echo yes || echo no)"

# AC 2: absent file → empty stdout, exit 0 (no-op path).
LPE_ABS_OUT="$(cd "$LPE_DIR" && bash "$LPE" pr-description 2>/dev/null)"; LPE_ABS_RC=$?
assert_eq "lpe: absent → empty stdout" "" "$LPE_ABS_OUT"
assert_eq "lpe: absent → exit 0" "0" "$LPE_ABS_RC"

# AC 3: empty file → empty stdout, exit 0.
: > "$LPE_DIR/.devflow/prompt-extensions/create-issue.md"
LPE_EMP_OUT="$(cd "$LPE_DIR" && bash "$LPE" create-issue 2>/dev/null)"; LPE_EMP_RC=$?
assert_eq "lpe: empty file → empty stdout" "" "$LPE_EMP_OUT"
assert_eq "lpe: empty file → exit 0" "0" "$LPE_EMP_RC"

# AC 5: path-traversal — reject '/' and '..' BEFORE any read, exit non-zero,
# print nothing. Sentinels the helper would leak if validation were absent:
#   name '../config'  → .devflow/prompt-extensions/../config.md = .devflow/config.md
printf 'SECRET-OUTSIDE' > "$LPE_DIR/.devflow/config.md"
for bad in "a/b" ".." "../config" "../../etc/passwd" "foo/../bar"; do
  BAD_OUT="$(cd "$LPE_DIR" && bash "$LPE" "$bad" 2>/dev/null)"; BAD_RC=$?
  assert_eq "lpe: reject '$bad' → exit non-zero" "yes" \
    "$([ "$BAD_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "lpe: reject '$bad' → reads nothing outside (empty stdout)" "" "$BAD_OUT"
done
# Empty skill name → bad arguments, exit non-zero.
EMPTY_NAME_OUT="$(cd "$LPE_DIR" && bash "$LPE" "" 2>/dev/null)"; EMPTY_NAME_RC=$?
assert_eq "lpe: empty skill name → exit non-zero" "yes" \
  "$([ "$EMPTY_NAME_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: empty skill name → empty stdout" "" "$EMPTY_NAME_OUT"

# Present-but-unreadable file → refused LOUDLY (exit 2 + breadcrumb), never the
# silent empty no-op the calling skill reads as "proceed unchanged" (which would
# drop the consumer's extension). Root bypasses the permission bits, so this only
# asserts for an ordinary user — skip under root rather than reporting a false FAIL.
printf 'unreadable content' > "$LPE_DIR/.devflow/prompt-extensions/locked.md"
chmod 000 "$LPE_DIR/.devflow/prompt-extensions/locked.md"
if [ "$(id -u)" -ne 0 ] && [ ! -r "$LPE_DIR/.devflow/prompt-extensions/locked.md" ]; then
  LOCK_OUT="$(cd "$LPE_DIR" && bash "$LPE" locked 2>/tmp/devflow-lpe-lock.err)"; LOCK_RC=$?
  assert_eq "lpe: unreadable present file → exit non-zero (not a silent no-op)" "yes" \
    "$([ "$LOCK_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "lpe: unreadable present file → no content leaked to stdout" "" "$LOCK_OUT"
  assert_eq "lpe: unreadable present file → breadcrumb names the file" "yes" \
    "$(grep -qF 'not readable' /tmp/devflow-lpe-lock.err && echo yes || echo no)"
fi
chmod 644 "$LPE_DIR/.devflow/prompt-extensions/locked.md"   # restore so rm -rf can clean up

# Broken symlink (present link, missing target) → refused LOUDLY (exit 2 +
# breadcrumb), not the silent no-op a bare `-f` test would yield — same silent-drop
# class as the unreadable guard, for an unresolvable link.
ln -s "./this-target-does-not-exist.md" "$LPE_DIR/.devflow/prompt-extensions/broken.md"
BROKEN_OUT="$(cd "$LPE_DIR" && bash "$LPE" broken 2>/tmp/devflow-lpe-broken.err)"; BROKEN_RC=$?
assert_eq "lpe: broken symlink (missing target) → exit non-zero (not silent no-op)" "yes" \
  "$([ "$BROKEN_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: broken symlink → empty stdout" "" "$BROKEN_OUT"
assert_eq "lpe: broken symlink → breadcrumb names the missing target" "yes" \
  "$(grep -qF 'missing target' /tmp/devflow-lpe-broken.err && echo yes || echo no)"
rm -f "$LPE_DIR/.devflow/prompt-extensions/broken.md"

# Present-but-not-a-regular-file → refused LOUDLY, not a silent no-op: a directory
# at <skill>.md (a fat-fingered `mkdir`) and a symlink resolving to a directory both
# have -f false and would otherwise drop the extension silently (same class).
mkdir "$LPE_DIR/.devflow/prompt-extensions/adir.md"
ADIR_OUT="$(cd "$LPE_DIR" && bash "$LPE" adir 2>/tmp/devflow-lpe-adir.err)"; ADIR_RC=$?
assert_eq "lpe: directory at <skill>.md → exit non-zero (not silent no-op)" "yes" \
  "$([ "$ADIR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: directory at <skill>.md → breadcrumb 'not a regular file'" "yes" \
  "$(grep -qF 'not a regular file' /tmp/devflow-lpe-adir.err && echo yes || echo no)"
mkdir "$LPE_DIR/realdir"
ln -s "../../realdir" "$LPE_DIR/.devflow/prompt-extensions/dirlink.md"
DIRLINK_OUT="$(cd "$LPE_DIR" && bash "$LPE" dirlink 2>/dev/null)"; DIRLINK_RC=$?
assert_eq "lpe: symlink resolving to a directory → exit non-zero (not silent no-op)" "yes" \
  "$([ "$DIRLINK_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: symlink-to-directory → empty stdout" "" "$DIRLINK_OUT"
rm -rf "$LPE_DIR/.devflow/prompt-extensions/adir.md" "$LPE_DIR/.devflow/prompt-extensions/dirlink.md" "$LPE_DIR/realdir"

# Intended symlink behavior (pins a DECISION, not an accident): the name guard
# constrains the model-supplied NAME, not the resolved target. A symlink the repo
# owner commits inside the consumer-owned extensions dir IS followed by `cat` — the
# directory's contents are trusted by design. This documents that AC 5's "reads no
# file outside" is a name-confinement guarantee, not symlink-target confinement.
printf 'TARGET-OF-SYMLINK' > "$LPE_DIR/symlink-target.txt"
ln -s "../../symlink-target.txt" "$LPE_DIR/.devflow/prompt-extensions/linked.md"
LINK_OUT="$(cd "$LPE_DIR" && bash "$LPE" linked 2>/dev/null)"; LINK_RC=$?
assert_eq "lpe: symlinked extension inside the dir is followed (consumer-owned, by design)" \
  "TARGET-OF-SYMLINK" "$LINK_OUT"
assert_eq "lpe: symlinked extension → exit 0" "0" "$LINK_RC"

# AC 8: read-only + idempotent — identical output on re-run, source file unchanged.
printf 'idem\n' > "$LPE_DIR/.devflow/prompt-extensions/init.md"
LPE_IDEM1="$(cd "$LPE_DIR" && bash "$LPE" init 2>/dev/null)"
LPE_CKSUM_BEFORE="$(cksum "$LPE_DIR/.devflow/prompt-extensions/init.md")"
LPE_IDEM2="$(cd "$LPE_DIR" && bash "$LPE" init 2>/dev/null)"
LPE_CKSUM_AFTER="$(cksum "$LPE_DIR/.devflow/prompt-extensions/init.md")"
assert_eq "lpe: idempotent — identical output on re-run" "$LPE_IDEM1" "$LPE_IDEM2"
assert_eq "lpe: read-only — source file unchanged after run" \
  "$LPE_CKSUM_BEFORE" "$LPE_CKSUM_AFTER"
rm -rf "$LPE_DIR"

# ────────────────────────────────────────────────────────────────────────────
echo "load-prompt-extension.sh: every skills/*/SKILL.md carries the standardized step"
# ────────────────────────────────────────────────────────────────────────────
# Coverage / drift guard (issue #84, AC 6 + AC 7). The standardized step spans
# every skill's SKILL.md; this enumeration is the enforcement that keeps them in
# sync (same drift hazard as the exclusion-list-sync requirement). Pin BOTH the
# canonical helper path-suffix AND the skill's own directory name so a copy-paste
# of the wrong skill name, a half-applied removal, or a path drift all fail here
# rather than shipping silently. Fails when a future skill omits the step.
LPE_SKILL_COUNT=0
for SKILL_DIR in "$LIB"/../skills/*/; do
  SKILL_NAME="$(basename "$SKILL_DIR")"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  LPE_SKILL_COUNT=$((LPE_SKILL_COUNT + 1))
  # Anchor the name to a trailing boundary (end-of-line or whitespace) so a short
  # name that is a prefix of a sibling (docs vs docs-verify, review vs review-and-fix,
  # retrospective vs retrospective-weekly) cannot vacuously match the sibling's
  # invocation — the guard's whole job is pinning each skill's OWN directory name.
  assert_eq "lpe-coverage: $SKILL_NAME/SKILL.md invokes the helper for its own name" "yes" \
    "$([ -f "$SKILL_FILE" ] && grep -qE "load-prompt-extension\.sh $SKILL_NAME(\$|[[:space:]])" "$SKILL_FILE" && echo yes || echo no)"
done
# Guard against the loop becoming a vacuous no-op: if the skills/*/ glob ever
# matched nothing (a path typo, a restructure, a wrong CWD), the loop above would
# run zero assertions and the drift guard would silently pass. The guard's entire
# value is catching a future skill that ships without the step, so assert it
# actually enumerated the skills (>0; floor matches the current 16, kept as ≥1 so
# adding a skill never trips it).
assert_eq "lpe-coverage: enumeration is non-vacuous (skills/*/ glob matched)" "yes" \
  "$([ "$LPE_SKILL_COUNT" -ge 1 ] && echo yes || echo no)"

# ────────────────────────────────────────────────────────────────────────────
echo "shipped agent_overrides: deduper pins Sonnet 4.6 w/ effort; no Haiku override carries effort"
# ────────────────────────────────────────────────────────────────────────────
# The shipped checklist-deduper override pins Claude Sonnet 4.6 (which DOES
# support `effort`) with effort "medium" — Sonnet 4.6's recommended default, and
# effort must be set explicitly on Sonnet 4.6 to avoid unexpected latency. A
# positive sentinel, not a bare has("effort"): a refactor that drops/renames the
# entry, swaps the model, or strips the effort each FAIL loudly rather than
# sailing through green. The entry must positively EXIST, be object-typed, pin
# claude-sonnet-4-6, AND carry an `effort` key — so a dropped/renamed entry
# ("missing-entry"), a model no longer Sonnet 4.6 ("not-sonnet"), or a removed
# effort ("no-effort") each FAIL loudly.
assert_eq "agent_overrides: shipped deduper override exists, pins Sonnet 4.6, and carries an effort key" \
  "ok" \
  "$(jq -r '
      (.devflow_review.agent_overrides["devflow:checklist-deduper"]) as $d
      | if ($d | type) != "object" then "missing-entry"
        elif (($d.model // "") != "claude-sonnet-4-6") then "not-sonnet"
        elif ($d | has("effort") | not) then "no-effort"
        else "ok" end' "$TPL_DIR/config.example.json")"
# Claude Haiku rejects `effort` with HTTP 400 (supported only on Opus 4.5–4.8 /
# Sonnet 4.6). The shipped example no longer pins Haiku anywhere, but this guard
# keeps the invariant the scaffold-config.sh cleanup protects: should any shipped
# override ever pin a Haiku model, it must NOT also carry an `effort` key.
assert_eq "agent_overrides: no shipped Haiku-pinned override carries an effort key" \
  "ok" \
  "$(jq -r '
      [ (.devflow_review.agent_overrides // {}) | to_entries[]
        | select((.value | type) == "object")
        | select(((.value.model // "") | startswith("claude-haiku-")) and (.value | has("effort"))) ]
      | if length == 0 then "ok" else "haiku-with-effort" end' "$TPL_DIR/config.example.json")"

# ────────────────────────────────────────────────────────────────────────────
echo "config.example.json ⊇ config.schema.json (superset invariant)"
# ────────────────────────────────────────────────────────────────────────────
# config.example.json drives the scaffold/backfill (scaffold-config.sh copies it
# verbatim to a fresh config.json); config.schema.json drives editor validation.
# They are hand-maintained independently, so a key in one but not the other
# silently either won't backfill (a schema default with no example entry never
# reaches a scaffolded config) or is an undocumented/typo'd key the schema does
# not describe. These two assertions pin the relation in both directions:
#   1. every object key in the example is a property the schema defines (catches
#      typo'd / undocumented keys — the schema is additionalProperties:true, so
#      such a key would still *validate*, it would just go unnoticed).
#   2. every schema property carrying a `default` is present in the example (so a
#      backfilled config.json actually carries every defaulted key).
# Scope of the comparison (what is and isn't checked):
#   - Only OBJECT-key paths are compared. Keys nested inside example array
#     ELEMENTS are out of scope — the example has no array-of-object entries
#     (setup.install is a scalar array), and such keys would validate under
#     additionalProperties anyway; kpaths drops array-index paths accordingly.
#   - Optional schema properties with NO default (php_*, services,
#     watched_authors, node_working_directory, …) are intentionally omitted from
#     the example and so are NOT required by check 2.
#   - Defaults are collected from object properties only — dpaths does not
#     descend into array `items`: a default on an array element cannot be
#     satisfied by the (element-less) example, so check 2 would otherwise be
#     permanently unsatisfiable. spaths DOES descend into items so check 1's
#     allowed-key set stays complete (e.g. setup.services.[].image).
# A non-empty list on either side is the drift.
CFG_EXAMPLE="$TPL_DIR/config.example.json"
CFG_SCHEMA="$TPL_DIR/config.schema.json"
CFG_DRIFT="$(jq -n '
  # Property-name paths the schema DEFINES (descends into .properties + .items).
  def spaths:
    def recur($p):
      ( (.properties // {}) | to_entries[] | ($p+[.key]) as $q
        | ($q|join(".")), (.value|recur($q)) ),
      ( (.items // empty) | recur($p+["[]"]) );
    [ recur([]) ];
  # Schema OBJECT-property paths that declare a `default` (the backfillable
  # keys). Deliberately does NOT descend into array `items` — see the scope
  # note above for why an array-element default would make check 2 unsatisfiable.
  def dpaths:
    def recur($p):
      (.properties // {}) | to_entries[] | ($p+[.key]) as $q
      | (if (.value | (type=="object" and has("default"))) then ($q|join(".")) else empty end),
        (.value|recur($q));
    [ recur([]) ];
  # Object-key paths present in the example (array indices excluded).
  def kpaths:
    [ paths | select(all(.[]; type=="string")) | join(".") ];
  input as $ex | input as $sch
  | { example_not_in_schema:        (($ex|kpaths) - ($sch|spaths) | sort),
      schema_default_not_in_example: (($sch|dpaths) - ($ex|kpaths) | sort) }
' "$CFG_EXAMPLE" "$CFG_SCHEMA")"
assert_eq "config: every example key is defined in the schema" "[]" \
  "$(echo "$CFG_DRIFT" | jq -c '.example_not_in_schema')"
assert_eq "config: every schema default appears in the example" "[]" \
  "$(echo "$CFG_DRIFT" | jq -c '.schema_default_not_in_example')"

# ────────────────────────────────────────────────────────────────────────────
echo "detect-project-tools.sh"
# ────────────────────────────────────────────────────────────────────────────
# Language auto-detection: scans a throwaway repo for marker files and merges
# the matching presets (from the repo's real .devflow/tool-presets.json) into a
# .devflow/config.json. Run by scaffold-config.sh, so a regression here silently
# wires the wrong tools into the cloud reviewer.
DPT="$LIB/../scripts/detect-project-tools.sh"

# Helper: does an allowlist contain a tool pattern?
dpt_has() { jq -e --arg t "$2" "$1 | index(\$t) != null" "$3" >/dev/null 2>&1 && echo yes || echo no; }

# 1. Node + npm lockfile → tools land in ALL THREE paths; node_version filled;
#    `npm ci` chosen from package-lock.json; an existing custom entry is kept
#    at the front (ordered union, not alphabetical); install order preserved.
DT1="$(mktemp -d)"; mkdir -p "$DT1/.devflow"
printf '{"name":"x"}' > "$DT1/package.json"
printf '{}' > "$DT1/package-lock.json"
printf '{"devflow":{"allowed_tools":["Bash(make:*)"]},"setup":{"node_version":"","install":["python -m pip install pyyaml"]}}' > "$DT1/.devflow/config.json"
bash "$DPT" "$DT1" >/dev/null 2>&1
assert_eq "detect: npm tool in devflow path"   "yes" "$(dpt_has .devflow.allowed_tools           'Bash(npm:*)' "$DT1/.devflow/config.json")"
assert_eq "detect: npm tool in implement path" "yes" "$(dpt_has .devflow_implement.allowed_tools 'Bash(npm:*)' "$DT1/.devflow/config.json")"
assert_eq "detect: npm tool in runner path"    "yes" "$(dpt_has .devflow_runner.allowed_tools    'Bash(npm:*)' "$DT1/.devflow/config.json")"
assert_eq "detect: node_version filled from empty" "20" \
  "$(jq -r '.setup.node_version' "$DT1/.devflow/config.json")"
assert_eq "detect: npm ci chosen from package-lock.json" "yes" \
  "$(jq -e '.setup.install | index("npm ci") != null' "$DT1/.devflow/config.json" >/dev/null && echo yes || echo no)"
assert_eq "detect: existing custom tool preserved at front (ordered union)" "Bash(make:*)" \
  "$(jq -r '.devflow.allowed_tools[0]' "$DT1/.devflow/config.json")"
assert_eq "detect: pyyaml install line kept first (order preserved)" "python -m pip install pyyaml" \
  "$(jq -r '.setup.install[0]' "$DT1/.devflow/config.json")"
# Negative assertion: the rename must not leave a phantom `claude` object behind
# (a stale `.claude = (.claude // {})` jq initializer would silently inject one).
assert_eq "detect: no stray legacy 'claude' key written" "true" \
  "$(jq -e '.claude == null' "$DT1/.devflow/config.json" >/dev/null && echo true || echo false)"

# 2. Idempotent: a second run changes nothing.
DT1_HASH="$(jq -S . "$DT1/.devflow/config.json" | sha256sum)"
bash "$DPT" "$DT1" >/dev/null 2>&1
assert_eq "detect: idempotent re-run is a no-op" \
  "$DT1_HASH" "$(jq -S . "$DT1/.devflow/config.json" | sha256sum)"

# 3. A pinned node_version is NEVER overridden; no lockfile → `npm install`.
DT2="$(mktemp -d)"; mkdir -p "$DT2/.devflow"
printf '{"name":"y"}' > "$DT2/package.json"
printf '{"setup":{"node_version":"18","install":[]}}' > "$DT2/.devflow/config.json"
bash "$DPT" "$DT2" >/dev/null 2>&1
assert_eq "detect: pinned node_version not overridden" "18" \
  "$(jq -r '.setup.node_version' "$DT2/.devflow/config.json")"
assert_eq "detect: no lockfile → npm install" "yes" \
  "$(jq -e '.setup.install | index("npm install") != null' "$DT2/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 4. False-positive guard: a marker ONLY inside node_modules must NOT match —
#    config stays exactly the empty object it started as.
DT3="$(mktemp -d)"; mkdir -p "$DT3/.devflow" "$DT3/node_modules/foo"
printf '{"x":1}' > "$DT3/node_modules/foo/package.json"
printf '{}' > "$DT3/.devflow/config.json"
bash "$DPT" "$DT3" >/dev/null 2>&1
assert_eq "detect: vendored node_modules marker does not trigger" "{}" \
  "$(jq -c . "$DT3/.devflow/config.json")"

# 5. Glob marker (*.csproj) matches dotnet.
DT4="$(mktemp -d)"; mkdir -p "$DT4/.devflow"
printf '<Project/>' > "$DT4/App.csproj"
printf '{}' > "$DT4/.devflow/config.json"
bash "$DPT" "$DT4" >/dev/null 2>&1
assert_eq "detect: *.csproj glob matches dotnet" "yes" \
  "$(dpt_has .devflow_runner.allowed_tools 'Bash(dotnet:*)' "$DT4/.devflow/config.json")"

# 6. PHP (composer.json) → php tools in all paths AND a composer install line.
DT5="$(mktemp -d)"; mkdir -p "$DT5/.devflow"
printf '{"require":{"php":">=8.2"}}' > "$DT5/composer.json"
printf '{}' > "$DT5/.devflow/config.json"
bash "$DPT" "$DT5" >/dev/null 2>&1
assert_eq "detect: composer tool in runner path" "yes" \
  "$(dpt_has .devflow_runner.allowed_tools 'Bash(composer:*)' "$DT5/.devflow/config.json")"
assert_eq "detect: composer install line added" "yes" \
  "$(jq -e '.setup.install | index("composer install --no-interaction --prefer-dist --no-progress") != null' "$DT5/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 7. Subdirectory Node build (package.json + lockfile under jsx/) → detection
#    sets node_working_directory to the subdir AND scopes the install line into
#    it with a subshell `cd` (not a root-level npm ci that would no-op).
DT6="$(mktemp -d)"; mkdir -p "$DT6/.devflow" "$DT6/jsx"
printf '{"name":"bundle"}' > "$DT6/jsx/package.json"
printf '{}' > "$DT6/jsx/package-lock.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT6/.devflow/config.json"
bash "$DPT" "$DT6" >/dev/null 2>&1
assert_eq "detect: subdir build sets node_working_directory" "jsx" \
  "$(jq -r '.setup.node_working_directory' "$DT6/.devflow/config.json")"
assert_eq "detect: subdir install line is subshell-scoped into the dir (quoted)" "yes" \
  "$(jq -e '.setup.install | index("(cd '\''jsx'\'' && npm ci)") != null' "$DT6/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 8. Root Node build → node_working_directory is NEVER written (byte-identical
#    to the pre-feature behavior) and the install line stays a bare npm ci.
DT7="$(mktemp -d)"; mkdir -p "$DT7/.devflow"
printf '{"name":"rootapp"}' > "$DT7/package.json"
printf '{}' > "$DT7/package-lock.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT7/.devflow/config.json"
bash "$DPT" "$DT7" >/dev/null 2>&1
assert_eq "detect: root build writes no node_working_directory key" "true" \
  "$(jq -e '.setup | has("node_working_directory") | not' "$DT7/.devflow/config.json" >/dev/null && echo true || echo false)"
assert_eq "detect: root build install line is bare npm ci (no cd)" "yes" \
  "$(jq -e '.setup.install | index("npm ci") != null' "$DT7/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 9. Subdirectory npm-shrinkwrap.json (the 4th lockfile) → detected just like
#    package-lock.json, mapping to `npm ci`, so detection stays consistent with
#    resolve-node-cache.sh / action.yml (which both honor shrinkwrap).
DT8="$(mktemp -d)"; mkdir -p "$DT8/.devflow" "$DT8/jsx"
printf '{"name":"bundle"}' > "$DT8/jsx/package.json"
printf '{}' > "$DT8/jsx/npm-shrinkwrap.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT8/.devflow/config.json"
bash "$DPT" "$DT8" >/dev/null 2>&1
assert_eq "detect: subdir npm-shrinkwrap.json sets node_working_directory" "jsx" \
  "$(jq -r '.setup.node_working_directory' "$DT8/.devflow/config.json")"
assert_eq "detect: subdir shrinkwrap install line is (cd 'jsx' && npm ci)" "yes" \
  "$(jq -e '.setup.install | index("(cd '\''jsx'\'' && npm ci)") != null' "$DT8/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 10. A subdirectory name containing a space is single-quoted in the generated
#     install line, so it survives the `bash -c` exec in the action verbatim.
DT9="$(mktemp -d)"; mkdir -p "$DT9/.devflow" "$DT9/my app"
printf '{"name":"bundle"}' > "$DT9/my app/package.json"
printf '{}' > "$DT9/my app/package-lock.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT9/.devflow/config.json"
bash "$DPT" "$DT9" >/dev/null 2>&1
assert_eq "detect: spaced subdir name is quoted in install line" "yes" \
  "$(jq -e '.setup.install | index("(cd '\''my app'\'' && npm ci)") != null' "$DT9/.devflow/config.json" >/dev/null && echo yes || echo no)"
assert_eq "detect: spaced subdir name written verbatim to node_working_directory" "my app" \
  "$(jq -r '.setup.node_working_directory' "$DT9/.devflow/config.json")"

# 11. Best-effort shape guard: a malformed pre-existing config (numeric
#     node_version, which the schema types as a string) is carried through the
#     merge into valid-but-wrong-shaped JSON. The guard must REFUSE to write it —
#     the user's config is left byte-identical — and the script must still exit 0
#     (best-effort, never blocks the surrounding scaffold).
DT10="$(mktemp -d)"; mkdir -p "$DT10/.devflow"
printf '{"name":"z"}' > "$DT10/package.json"
printf '{}' > "$DT10/package-lock.json"
printf '{"setup":{"node_version":20,"install":[]}}' > "$DT10/.devflow/config.json"
DT10_BEFORE="$(cat "$DT10/.devflow/config.json")"
bash "$DPT" "$DT10" >/dev/null 2>&1
assert_eq "detect: shape-drifted merge still exits 0 (best-effort)" "0" "$?"
assert_eq "detect: shape-drifted merge leaves config untouched" \
  "$DT10_BEFORE" "$(cat "$DT10/.devflow/config.json")"

# 12. The shape guard does NOT block a well-formed merge: a valid empty config
#     with a node marker is merged and written (npm tools land), confirming the
#     guard is a safety net, not a gate on the happy path.
DT11="$(mktemp -d)"; mkdir -p "$DT11/.devflow"
printf '{"name":"ok"}' > "$DT11/package.json"
printf '{}' > "$DT11/package-lock.json"
printf '{}' > "$DT11/.devflow/config.json"
bash "$DPT" "$DT11" >/dev/null 2>&1
assert_eq "detect: well-formed merge passes the guard and is written" "yes" \
  "$(dpt_has .devflow.allowed_tools 'Bash(npm:*)' "$DT11/.devflow/config.json")"

# 13. Windows regression: the native Windows jq build (winget jqlang.jq, run
#     under Git Bash) terminates every stdout line with CRLF. The marker/preset
#     read loops must strip the trailing CR — otherwise `read` captures keys like
#     $'node\r', the `.presets[$k]` lookup asks for a key that doesn't exist, and
#     a repo with valid markers is reported as "no known language markers". We
#     can't install a Windows jq in CI, so we shadow jq on PATH with a wrapper
#     that appends a CR to every output line (a faithful stand-in) and confirm a
#     plain Node repo is still detected end-to-end.
DT12="$(mktemp -d)"; mkdir -p "$DT12/.devflow" "$DT12/bin"
printf '{"name":"win"}' > "$DT12/package.json"
printf '{}' > "$DT12/package-lock.json"
printf '{}' > "$DT12/.devflow/config.json"
DT12_REAL_JQ="$(command -v jq)"
cat > "$DT12/bin/jq" <<EOF
#!/usr/bin/env bash
# Stand-in for the native Windows jq: delegate to real jq, then CRLF every line.
"$DT12_REAL_JQ" "\$@" | awk '{ printf "%s\r\n", \$0 }'
EOF
chmod +x "$DT12/bin/jq"
# Sanity guard: confirm the shim actually injects CRLF. Without this, a future
# break in the wrapper would turn the regression test below into a passing
# no-op (it would assert "yes" even with the fix removed). If this fails, the
# CRLF path is no longer being exercised — fix the shim, not the assertion.
assert_eq "detect(DT12 control): jq shim emits CRLF" "yes" \
  "$(PATH="$DT12/bin:$PATH" jq -n '1' | grep -q $'\r' && echo yes || echo no)"
PATH="$DT12/bin:$PATH" bash "$DPT" "$DT12" >/dev/null 2>&1
assert_eq "detect: CRLF jq stdout (Windows) exits 0" "0" "$?"
assert_eq "detect: CRLF jq stdout (Windows) still detects node markers" "yes" \
  "$(dpt_has .devflow.allowed_tools 'Bash(npm:*)' "$DT12/.devflow/config.json")"

rm -rf "$DT1" "$DT2" "$DT3" "$DT4" "$DT5" "$DT6" "$DT7" "$DT8" "$DT9" "$DT10" "$DT11" "$DT12"

# ────────────────────────────────────────────────────────────────────────────
echo "resolve-node-cache.sh (setup-project-env helper)"
# ────────────────────────────────────────────────────────────────────────────
# Resolves setup-node's `cache` / `cache-dependency-path` for a Node project
# that may live in a subdirectory. The script probes lockfiles relative to cwd,
# so each case runs it from a throwaway repo root. A regression here silently
# disables caching for subdir builds or — worse — regresses root-based ones.
RNC="$LIB/../.github/actions/setup-project-env/resolve-node-cache.sh"
rnc() { ( cd "$1" && bash "$RNC" "$2" "${3:-}" ); }

# Subdirectory lockfile + node_working_directory set → caching enabled, path
# qualified by the directory.
RNC_SUB="$(mktemp -d)"; mkdir -p "$RNC_SUB/jsx"; : > "$RNC_SUB/jsx/package-lock.json"
RNC_OUT="$(rnc "$RNC_SUB" 20 jsx)"
assert_eq "rnc: subdir lockfile → npm cache"        "node_cache=npm" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: subdir lockfile → qualified path"   "node_cache_path=jsx/package-lock.json" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"
# Trailing slash on the directory is normalized (no doubled slash in the path).
RNC_OUT_TS="$(rnc "$RNC_SUB" 20 jsx/)"
assert_eq "rnc: trailing slash normalized"          "node_cache_path=jsx/package-lock.json" \
  "$(printf '%s\n' "$RNC_OUT_TS" | grep '^node_cache_path=')"

# Root lockfile, empty working directory → identical to the historical
# root-based outputs (no regression).
RNC_ROOT="$(mktemp -d)"; : > "$RNC_ROOT/yarn.lock"
RNC_OUT="$(rnc "$RNC_ROOT" 20 "")"
assert_eq "rnc: root yarn.lock → yarn cache"        "node_cache=yarn" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: root yarn.lock → bare path"         "node_cache_path=yarn.lock" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"

# pnpm wins over a co-present npm lockfile (precedence preserved).
RNC_PREC="$(mktemp -d)"; : > "$RNC_PREC/pnpm-lock.yaml"; : > "$RNC_PREC/package-lock.json"
assert_eq "rnc: pnpm precedence over npm"           "node_cache=pnpm" \
  "$(rnc "$RNC_PREC" 20 "" | grep '^node_cache=')"

# npm-shrinkwrap.json (the 4th lockfile) → npm cache, qualified path.
RNC_SHR="$(mktemp -d)"; mkdir -p "$RNC_SHR/jsx"; : > "$RNC_SHR/jsx/npm-shrinkwrap.json"
RNC_OUT="$(rnc "$RNC_SHR" 20 jsx)"
assert_eq "rnc: subdir shrinkwrap → npm cache"      "node_cache=npm" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: subdir shrinkwrap → qualified path" "node_cache_path=jsx/npm-shrinkwrap.json" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"

# Working directory set but no lockfile in it (config drift: dir named but
# lockfile not committed there) → caching off, so setup-node never errors.
RNC_WDNF="$(mktemp -d)"; mkdir -p "$RNC_WDNF/jsx"
assert_eq "rnc: working dir set but no lockfile → empty cache" "node_cache=" \
  "$(rnc "$RNC_WDNF" 20 jsx | grep '^node_cache=')"

# No lockfile → caching disabled (empty), so setup-node never errors.
RNC_NONE="$(mktemp -d)"
RNC_OUT="$(rnc "$RNC_NONE" 20 "")"
assert_eq "rnc: no lockfile → empty cache"          "node_cache=" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: no lockfile → empty path"           "node_cache_path=" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"

# Empty node_version → caching off even when a lockfile is present (the "Node
# not provisioned" case — setup-node won't run, so a cache key is meaningless).
assert_eq "rnc: empty node_version → no cache"      "node_cache=" \
  "$(rnc "$RNC_ROOT" "" "" | grep '^node_cache=')"

rm -rf "$RNC_SUB" "$RNC_ROOT" "$RNC_PREC" "$RNC_SHR" "$RNC_WDNF" "$RNC_NONE"

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
# watched_authors falls back to devflow.allowed_bots when the override array is absent.
( wp="$(mktemp)"; printf '{"devflow":{"allowed_bots":"claude,fallback-bot"}}' > "$wp"
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
# 404); default is a clean success echoing STUB_PERM. STUB_RECOVER (with a
# STUB_COUNTER file) fails the FIRST permission call with a 500 and succeeds on
# the second, so a test can prove the resolver's retry loop actually re-attempts.
case "$*" in
  *"collaborators/"*"/permission"*)
    if [ -n "${STUB_RECOVER:-}" ]; then
      n=0; [ -f "${STUB_COUNTER:-/dev/null}" ] && n="$(cat "${STUB_COUNTER:-/dev/null}")"
      n=$((n + 1)); echo "$n" > "${STUB_COUNTER:-/dev/null}"
      if [ "$n" -lt 2 ]; then echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; fi
      echo "${STUB_PERM:-none}"; exit 0
    fi
    [ -n "${STUB_ERR:-}" ] && echo "$STUB_ERR" >&2
    [ "${STUB_RC:-0}" != 0 ] && exit "${STUB_RC}"
    echo "${STUB_PERM:-none}" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$RIT_STUB_DIR/gh"

# 1. Allowed bot + explicit number in comment → run on that number. `foo[bot]`
#    actor must match the bare `foo` in allowed_bots. No gh call on this path.
OUT="$(ACTOR='foo[bot]' ALLOWED_BOTS='foo,bar' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement #42' CONTEXT_NUMBER='7' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: allowed bot, explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: allowed bot, explicit number → number" \
  "number=42" "$(echo "$OUT" | grep '^number=')"

# 2. Write collaborator + explicit number in comment → run on that number.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='write' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: write collaborator, explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: explicit number beats context" \
  "number=7" "$(echo "$OUT" | grep '^number=')"

# 3. Non-collaborator (gh → 'none') → blocked, no number.
OUT="$(ACTOR='stranger' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='none' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: non-collaborator → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: non-collaborator → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"

# 4. Authorized but NO number anywhere → blocked (can't implement nothing).
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement please' CONTEXT_NUMBER='' \
  STUB_PERM='admin' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: no resolvable number → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 5. Authorized, no explicit number but a context issue → fall back to context.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement' CONTEXT_NUMBER='5' \
  STUB_PERM='maintain' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: fallback to context number" \
  "number=5" "$(echo "$OUT" | grep '^number=')"

# 6. Transient collaborator-API failure (non-404) → fails CLOSED with a
#    transient-specific diagnostic, NOT mislabelled as "not a collaborator".
#    RESOLVE_RETRY_DELAY=0 keeps the retry instant.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RC='1' STUB_ERR='gh: Internal Server Error (HTTP 500)' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT" 2>"$RIT_STUB_DIR/err")"
assert_eq "rit: transient API error → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: transient API error → honest diagnostic (not mislabelled)" \
  "1" "$(grep -c 'collaborator-permission lookup failed after retry' "$RIT_STUB_DIR/err")"
assert_eq "rit: transient API error → surfaces the real gh error" \
  "1" "$(grep -c 'HTTP 500' "$RIT_STUB_DIR/err")"

# 7. Genuine 404 (not a collaborator) → fails closed as before, no retry stall.
OUT="$(ACTOR='stranger' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RC='1' STUB_ERR='gh: Not Found (HTTP 404)' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT" 2>"$RIT_STUB_DIR/err")"
assert_eq "rit: 404 non-collaborator → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: 404 treated as non-collaborator, not transient" \
  "1" "$(grep -c 'is not an allowed bot or write/admin/maintain collaborator' "$RIT_STUB_DIR/err")"

# 8. Transient failure on attempt 1, success on attempt 2 → retry RECOVERS the
#    collaborator. A regression collapsing the loop to a single call would fail
#    closed and break this, which case 6 (double-failure) cannot catch.
RIT_COUNTER="$RIT_STUB_DIR/recover_count"; : > "$RIT_COUNTER"
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RECOVER='1' STUB_COUNTER="$RIT_COUNTER" STUB_PERM='write' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: retry recovers collaborator on attempt 2 → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: retry recovers → number" \
  "number=7" "$(echo "$OUT" | grep '^number=')"

# 9. Explicit number with leading '#' and mixed-case command → extracted (pins
#    the regex's `#?` arm and grep -i case-insensitivity).
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/DevFlow:Implement #13' CONTEXT_NUMBER='99' \
  STUB_PERM='admin' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: '#'-prefixed mixed-case command → number=13" \
  "number=13" "$(echo "$OUT" | grep '^number=')"

# 10. allowed_bots with surrounding whitespace + bot is NOT the first entry →
#     matched after parameter-expansion trim (pins the trim + loop continuation).
OUT="$(ACTOR='bar[bot]' ALLOWED_BOTS=' foo , bar ' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 8' CONTEXT_NUMBER='8' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: whitespace-trimmed, non-first allowed bot → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"

# 11. Self-trigger guard: a Devflow-authored workpad comment (leads with the
#     marker, quotes a `/devflow:implement run started` note) must NOT fire a
#     run — even for an allowed bot, since the guard runs BEFORE authorization
#     and number resolution. Covers the issue #25 regression directly.
RIT_WORKPAD_TEXT=$'<!-- devflow:workpad -->\n# DevFlow Workpad — Issue #25\n\n## Decisions / Notes\n### Setup\n- 04:57:07 — /devflow:implement run started'
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT="$RIT_WORKPAD_TEXT" CONTEXT_NUMBER='25' \
  SELF_COMMENT_MARKER='<!-- devflow:workpad -->' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: workpad-marker body → should_run=false (self-trigger guard)" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: workpad-marker body → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"

# 12. The guard's marker defaults to workpad.py's fallback when
#     SELF_COMMENT_MARKER is unset, so a workpad body is guarded regardless.
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT="$RIT_WORKPAD_TEXT" CONTEXT_NUMBER='25' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: default marker guards workpad body when SELF_COMMENT_MARKER unset" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 13. Sanity: a genuine command WITHOUT the marker is unaffected — the guard
#     must not over-match (allowed bot, explicit number, marker env present).
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 25' CONTEXT_NUMBER='25' \
  SELF_COMMENT_MARKER='<!-- devflow:workpad -->' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: no-marker command still runs (guard does not over-match)" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: no-marker command → parsed number" \
  "number=25" "$(echo "$OUT" | grep '^number=')"

rm -rf "$RIT_STUB_DIR"

# ────────────────────────────────────────────────────────────────────────────
echo "dedupe-implement-run.sh"
# ────────────────────────────────────────────────────────────────────────────
# Per-thread duplicate detection for /devflow:implement. GitHub has no native
# "skip if already running", so this gate-stage check decides duplicate=true
# when an OLDER active run for the same issue/PR thread exists, letting the
# workflow skip the billable job and leave the in-flight run untouched. The gh
# `run list` call is stubbed via DEVFLOW_GH; DEDUPE_RUNS_JSON feeds the run set
# and DEDUPE_GH_RC simulates a query failure.
DIR="$LIB/../scripts/dedupe-implement-run.sh"
DI_STUB="$(mktemp -d)"
cat > "$DI_STUB/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"run list"*)
    [ -n "${DI_ARGS_REC:-}" ] && echo "$*" >> "$DI_ARGS_REC"
    [ -n "${DEDUPE_GH_RC:-}" ] && exit "$DEDUPE_GH_RC"
    printf '%s' "${DEDUPE_RUNS_JSON:-[]}" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$DI_STUB/gh"
di() { DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID="$1" CONTEXT_NUMBER="$2" \
  DEDUPE_RUNS_JSON="$3" bash "$DIR" 2>/dev/null; }

# 1. An OLDER (smaller databaseId) active run for the same thread → duplicate.
assert_eq "di: older active run, same thread → duplicate" "duplicate=true" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]')"

# 2. A queued (not yet started) older run still counts as active → duplicate.
assert_eq "di: older QUEUED run, same thread → duplicate" "duplicate=true" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"queued"}]')"

# 3. A NEWER run (larger id) is NOT deferred to — this run is the older of the
#    two and proceeds; the newer one will defer to it. Guards against two
#    near-simultaneous commands BOTH skipping.
assert_eq "di: newer run, same thread → not duplicate (this run is older)" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":300,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]')"

# 4. An older active run for a DIFFERENT thread → not a duplicate (per-thread).
assert_eq "di: older run, different thread → not duplicate" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 43)","status":"in_progress"}]')"

# 5. Number-boundary: thread 2 must not match a run-name carrying thread 21.
assert_eq "di: thread 2 does not match 'issue 21'" "duplicate=false" \
  "$(di 200 2 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 21)","status":"in_progress"}]')"

# 6. A finished run (completed) is not active → not a duplicate.
assert_eq "di: completed run → not duplicate" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"completed"}]')"

# 7. Only this run itself in the list (id == RUN_ID) → not a duplicate.
assert_eq "di: self only → not duplicate" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":200,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]')"

# 8. No active runs at all → not a duplicate.
assert_eq "di: empty run list → not duplicate" "duplicate=false" \
  "$(di 200 42 '[]')"

# 9. gh query failure → fail OPEN (run proceeds), never silently swallowed.
assert_eq "di: gh failure → fail open (not duplicate)" "duplicate=false" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 DEDUPE_GH_RC=1 bash "$DIR" 2>/dev/null)"

# 10. Missing/invalid CONTEXT_NUMBER → fail open (cannot dedupe without a thread).
assert_eq "di: missing context number → fail open" "duplicate=false" \
  "$(di 200 '' '[]')"

# 11. Active-status set spanning 3+ overlapping runs: the OLDEST proceeds, a
#     middle run defers. Asserts the "exactly one of N proceeds" invariant beyond
#     the pairwise N=2 cases above (no double-skip across a 3-way race).
THREE='[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"},{"databaseId":200,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"},{"databaseId":300,"displayTitle":"DevFlow implement (issue 42)","status":"queued"}]'
assert_eq "di: 3-way race, oldest (id 100) → proceeds" "duplicate=false" "$(di 100 42 "$THREE")"
assert_eq "di: 3-way race, middle (id 200) → defers" "duplicate=true"  "$(di 200 42 "$THREE")"
assert_eq "di: 3-way race, newest (id 300) → defers" "duplicate=true"  "$(di 300 42 "$THREE")"

# 12. Malformed JSON (gh returned 200 + non-JSON, e.g. an HTML error page) → jq
#     fails, count is non-numeric → fail OPEN. Distinct path from the gh-exit
#     failure (#9) and missing-input (#10) cases.
assert_eq "di: malformed run-list JSON → fail open (not duplicate)" "duplicate=false" \
  "$(di 200 42 'not-json{')"

# 13. The run list MUST be scoped to --workflow devflow-implement.yml — otherwise
#     a same-numbered run of a DIFFERENT workflow (e.g. /devflow:review) could
#     spuriously suppress a legitimate /devflow:implement. Record the gh argv and
#     assert the flag is present.
DI_REC="$(mktemp)"
DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 DEDUPE_RUNS_JSON='[]' \
  DI_ARGS_REC="$DI_REC" bash "$DIR" >/dev/null 2>&1
assert_eq "di: run list is scoped to --workflow devflow-implement.yml" "1" \
  "$(grep -c -- '--workflow devflow-implement.yml' "$DI_REC")"
rm -f "$DI_REC"

# 14. The duplicate-ignored NOTICE must carry no DevFlow trigger phrase, or the
#     bot's own comment would re-fire devflow-implement.yml (self-trigger loop).
#     Assert the workflow's notice body is phrase-free.
NOTICE_LINE="$(grep -A2 'Notice — duplicate ignored' "$LIB/../.github/workflows/devflow-implement.yml" || true; \
  grep 'NOTE=' "$LIB/../.github/workflows/devflow-implement.yml" || true)"
# Guard against a vacuous pass: if the grep window ever stops capturing the notice
# body, grep -c on empty input returns 0 and the phrase-free checks pass without
# inspecting anything. Assert we actually captured the notice first.
assert_eq "di: notice test captured the notice body (no vacuous pass)" "1" \
  "$(grep -c 'already in progress' <<< "$NOTICE_LINE")"
assert_eq "di: duplicate notice contains no /devflow: phrase" "0" \
  "$(grep -c '/devflow:' <<< "$NOTICE_LINE")"
assert_eq "di: duplicate notice contains no @claude" "0" \
  "$(grep -c '@claude' <<< "$NOTICE_LINE")"

rm -rf "$DI_STUB"

# ────────────────────────────────────────────────────────────────────────────
echo "authorize-actor.sh (allowed_users filter)"
# ────────────────────────────────────────────────────────────────────────────
AUTH="$LIB/../scripts/authorize-actor.sh"
ASTUB="$(mktemp -d)"; cp "$LIB/test/fixtures/gh-stub.sh" "$ASTUB/gh"; chmod +x "$ASTUB/gh"
# Alice is the login the gh stub treats as a write/admin collaborator (mirrors
# the rit write-collaborator case: ACTOR='alice' STUB_PERM='write').
COLLAB="alice"
# shellcheck disable=SC1090,SC2154  # sources authorize-actor.sh at runtime; $authorized set there
run_auth() { ( PATH="$ASTUB:$PATH"; . "$AUTH"; authorize_actor; printf '%s' "$authorized" ); }
# shellcheck disable=SC1090,SC2154  # sources authorize-actor.sh at runtime; $deny_reason set there
run_auth_reason() { ( PATH="$ASTUB:$PATH"; . "$AUTH"; authorize_actor; printf '%s' "$deny_reason" ); }

# 1. Default (ALLOWED_USERS unset → '*') + collaborator → authorized.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" run_auth)"
assert_eq "auth: unset allowed_users + collaborator → authorized" "true" "$A"

# 2. Explicit '*' + collaborator → authorized.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="*" run_auth)"
assert_eq "auth: '*' + collaborator → authorized" "true" "$A"

# 3. allowed_users lists the actor + collaborator → authorized.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="$COLLAB,other" run_auth)"
assert_eq "auth: actor in allowed_users + collaborator → authorized" "true" "$A"

# 4. allowed_users does NOT list the actor → denied even though collaborator.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="alice-x,bob" run_auth)"
assert_eq "auth: collaborator not in allowed_users → denied" "false" "$A"
R="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="alice-x,bob" run_auth_reason)"
assert_eq "auth: deny_reason cites allowed_users" "is not in the configured allowed_users allowlist" "$R"

# 5. Bot in allowed_bots bypasses allowed_users entirely.
A="$(ACTOR="somebot" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="nobody" run_auth)"
assert_eq "auth: allowed bot bypasses allowed_users → authorized" "true" "$A"

rm -rf "$ASTUB"

# ────────────────────────────────────────────────────────────────────────────
echo "resolve-command-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# Light command dispatch (review / review-and-fix / pr-description) in AGENT
# mode. Authorizes the sender (allowed bot bypasses gh; otherwise allowed_users
# + collaborator), detects the command, and resolves a target number. Reuses
# gh-stub.sh (alice → write collaborator; any other actor → HTTP 404).
RCT="$LIB/../scripts/resolve-command-trigger.sh"
RCT_STUB="$(mktemp -d)"; cp "$LIB/test/fixtures/gh-stub.sh" "$RCT_STUB/gh"; chmod +x "$RCT_STUB/gh"

# 1. Allowed bot, /devflow:review with explicit number → review command.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="99" \
  TRIGGER_TEXT="/devflow:review #42" bash "$RCT")"
assert_eq "rct: review w/ explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rct: review w/ explicit number → command" \
  "command=/devflow:review 42" "$(echo "$OUT" | grep '^command=')"

# 2. review-and-fix must win over the /devflow:review substring it contains.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="7" \
  TRIGGER_TEXT="please run /devflow:review-and-fix now" bash "$RCT")"
assert_eq "rct: review-and-fix beats review substring → command" \
  "command=/devflow:review-and-fix 7" "$(echo "$OUT" | grep '^command=')"

# 3. pr-description, no explicit number → falls back to the context number.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="13" \
  TRIGGER_TEXT="/devflow:pr-description" bash "$RCT")"
assert_eq "rct: pr-description falls back to context number → command" \
  "command=/devflow:pr-description 13" "$(echo "$OUT" | grep '^command=')"

# 4. No devflow command present → should_run=false.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="1" \
  TRIGGER_TEXT="just a normal comment" bash "$RCT")"
assert_eq "rct: no command → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 5. Unauthorized actor (gh-stub 404 → not a collaborator) → should_run=false.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="random-user" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="5" \
  TRIGGER_TEXT="/devflow:review" bash "$RCT")"
assert_eq "rct: unauthorized actor → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

rm -rf "$RCT_STUB"

# ────────────────────────────────────────────────────────────────────────────
echo "react-to-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# Early-ack reaction. Picks the reactions endpoint by event type, defaults the
# content to `rocket`, and skips events with no reactions API (reviews). A `gh`
# stub records the `api` call args to $REACT_REC so we can assert the endpoint.
RT="$LIB/../scripts/react-to-trigger.sh"
RT_STUB="$(mktemp -d)"
cat > "$RT_STUB/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$REACT_REC"
STUB
chmod +x "$RT_STUB/gh"

# Per-case vars go through `env` because words from "$@" expansion are NOT
# honored as assignment prefixes (POSIX recognizes only literal tokens).
react() { REACT_REC="$(mktemp)"; PATH="$RT_STUB:$PATH" REACT_REC="$REACT_REC" GH_TOKEN=x env "$@" bash "$RT" >/dev/null 2>&1; }

# 1. issue_comment → react on the issue comment, default content rocket.
react EVENT_NAME=issue_comment REPO=o/r COMMENT_ID=555
assert_eq "react: issue_comment → issues/comments endpoint w/ rocket" \
  "1" "$(grep -c 'repos/o/r/issues/comments/555/reactions.*content=rocket' "$REACT_REC")"
rm -f "$REACT_REC"

# 2. pull_request_review_comment → react on the PR review comment.
react EVENT_NAME=pull_request_review_comment REPO=o/r COMMENT_ID=777
assert_eq "react: review comment → pulls/comments endpoint" \
  "1" "$(grep -c 'repos/o/r/pulls/comments/777/reactions' "$REACT_REC")"
rm -f "$REACT_REC"

# 3. issues (opened) → react on the issue itself.
react EVENT_NAME=issues REPO=o/r ISSUE_NUMBER=42
assert_eq "react: issues event → issues/<n> endpoint" \
  "1" "$(grep -c 'repos/o/r/issues/42/reactions' "$REACT_REC")"
rm -f "$REACT_REC"

# 4. pull_request_review has no reactions API → no call at all.
react EVENT_NAME=pull_request_review REPO=o/r COMMENT_ID=1
assert_eq "react: review event makes no api call" \
  "0" "$(grep -c 'reactions' "$REACT_REC")"
rm -f "$REACT_REC"

# 5. REACTION env overrides the default content.
react EVENT_NAME=issue_comment REPO=o/r COMMENT_ID=9 REACTION=eyes
assert_eq "react: REACTION env overrides default content" \
  "1" "$(grep -c 'content=eyes' "$REACT_REC")"
rm -f "$REACT_REC"

# 6. gh failure (e.g. HTTP 403 from a missing write scope) must NOT fail the
# step — best-effort: the script swallows it, exits 0, and warns to stderr with
# the gh error one-lined. This is the load-bearing error branch the success
# stub above can't reach (it always exits 0). A separate stub that prints a
# multi-line error to stderr and exits 1 exercises both the exit-0 guarantee
# and the `${err//$'\n'/ }` collapse.
FAIL_STUB="$(mktemp -d)"
cat > "$FAIL_STUB/gh" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP 403: Resource not accessible by integration\n(check issues/pull-requests write)\n' >&2
exit 1
STUB
chmod +x "$FAIL_STUB/gh"
react_err="$(PATH="$FAIL_STUB:$PATH" GH_TOKEN=x EVENT_NAME=issue_comment REPO=o/r COMMENT_ID=1 bash "$RT" 2>&1 >/dev/null)"
assert_eq "react: gh failure still exits 0 (best-effort, never blocks the run)" "0" "$?"
assert_eq "react: gh failure warns to stderr" \
  "1" "$(printf '%s\n' "$react_err" | grep -c '::warning::react: could not add')"
assert_eq "react: multi-line gh error is collapsed to one log line" \
  "1" "$(printf '%s\n' "$react_err" | grep -c 'integration (check issues')"
rm -rf "$FAIL_STUB"

rm -rf "$RT_STUB"

# ────────────────────────────────────────────────────────────────────────────
echo "install.sh: prune_stale_devflow_workflows"
# ────────────────────────────────────────────────────────────────────────────
# On upgrade, install.sh must remove DevFlow's OWN superseded claude*.yml but
# NEVER an Anthropic-owned claude.yml. Source the installer with
# DEVFLOW_SELFTEST=1 (defines the functions, skips the installer body) and run
# the prune function against throwaway repos.
INSTALL="$LIB/../install.sh"

# Case A: DevFlow-signed claude.yml + stale runner/implement → all removed.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.github/workflows"
printf '%s\n' "name: Claude Code" "  review_dedupe:" > "$WORK/.github/workflows/claude.yml"
echo "name: Claude Runner (reusable)" > "$WORK/.github/workflows/claude-runner.yml"
echo "name: Claude Code (implement)" > "$WORK/.github/workflows/claude-implement.yml"
# shellcheck disable=SC1090  # sources install.sh at runtime under DEVFLOW_SELFTEST
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_devflow_workflows ) >/dev/null 2>&1
assert_eq "install: devflow-signed claude.yml removed" \
  "absent" "$([ -f "$WORK/.github/workflows/claude.yml" ] && echo present || echo absent)"
assert_eq "install: stale claude-runner.yml removed" \
  "absent" "$([ -f "$WORK/.github/workflows/claude-runner.yml" ] && echo present || echo absent)"
assert_eq "install: stale claude-implement.yml removed" \
  "absent" "$([ -f "$WORK/.github/workflows/claude-implement.yml" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case B: Anthropic's own claude.yml (no DevFlow signature) → preserved.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.github/workflows"
printf '%s\n' "name: Claude Code" "  claude:" "    uses: anthropics/claude-code-action@v1" \
  > "$WORK/.github/workflows/claude.yml"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_devflow_workflows ) >/dev/null 2>&1
assert_eq "install: Anthropic claude.yml preserved" \
  "present" "$([ -f "$WORK/.github/workflows/claude.yml" ] && echo present || echo absent)"
rm -rf "$WORK"

# ────────────────────────────────────────────────────────────────────────────
echo "install.sh: prune_stale_vendored_plugin"
# ────────────────────────────────────────────────────────────────────────────
# On upgrade, install.sh must remove a stale committed plugin at the OLD
# .claude/plugins/devflow location (relocated to .devflow/vendor/devflow), but
# ONLY when it is actually DevFlow's plugin, and must never remove a non-empty
# user .claude/ directory.

# Case A: a DevFlow-signed tree at the old path → removed, empty parents pruned.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/.claude-plugin"
printf '{"name":"devflow"}' > "$WORK/.claude/plugins/devflow/.claude-plugin/plugin.json"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: stale committed .claude/plugins/devflow removed" \
  "absent" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
assert_eq "install: emptied .claude/ pruned" \
  "absent" "$([ -d "$WORK/.claude" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case B: a non-DevFlow plugin.json at that path → preserved (signature guard).
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/.claude-plugin"
printf '{"name":"not-devflow"}' > "$WORK/.claude/plugins/devflow/.claude-plugin/plugin.json"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: non-devflow .claude/plugins/devflow preserved" \
  "present" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case C: DevFlow tree removed but a non-empty .claude/ (other content) is kept.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/.claude-plugin" "$WORK/.claude/skills"
printf '{"name":"devflow"}' > "$WORK/.claude/plugins/devflow/.claude-plugin/plugin.json"
printf 'x' > "$WORK/.claude/skills/keep.md"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: devflow tree removed under non-empty .claude" \
  "absent" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
assert_eq "install: emptied .claude/plugins parent pruned, non-empty .claude kept" \
  "absent-present" "$([ -d "$WORK/.claude/plugins" ] && echo present || echo absent)-$([ -d "$WORK/.claude" ] && echo present || echo absent)"
assert_eq "install: non-empty user .claude/ preserved" \
  "present" "$([ -f "$WORK/.claude/skills/keep.md" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case D: no old tree at all (the common thin-install path) → clean no-op, exit 0,
# and an unrelated .claude/ is untouched.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/skills"; printf 'x' > "$WORK/.claude/skills/keep.md"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: prune is a clean no-op when no old tree exists" "0" "$?"
assert_eq "install: prune leaves unrelated .claude/ untouched when no old tree" \
  "present" "$([ -f "$WORK/.claude/skills/keep.md" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case E: old dir exists but carries no devflow plugin.json (partial/interrupted
# install) → left in place (not blindly removed), exit 0.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/scripts"
printf 'x' > "$WORK/.claude/plugins/devflow/scripts/stray.sh"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: unsigned old tree is a clean exit" "0" "$?"
assert_eq "install: unsigned old tree is left untouched" \
  "present" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
rm -rf "$WORK"

# ────────────────────────────────────────────────────────────────────────────
echo "install.sh: manage_vendor_gitignore"
# ────────────────────────────────────────────────────────────────────────────
# Thin installs must ignore the runtime-vendored .devflow/vendor/ tree so a
# cloud run's `git add -A` never commits it; DEVFLOW_VENDOR=1 commits it on
# purpose, so the ignore line must be absent there. Patterns are relative to
# .devflow/, matching the scaffolded `/tmp/` entry.

# Case A: thin install (DEVFLOW_VENDOR unset) → /vendor/ appended, /tmp/ kept.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/tmp/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: thin install ignores /vendor/" \
  "yes" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "install: thin install keeps /tmp/" \
  "yes" "$(grep -qxF '/tmp/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
# Idempotent: a second run does not duplicate the line.
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: thin /vendor/ ignore is idempotent" \
  "1" "$(grep -cxF '/vendor/' "$WORK/.devflow/.gitignore")"
rm -rf "$WORK"

# Case B: DEVFLOW_VENDOR=1 → a previously-added /vendor/ line is removed, /tmp/ kept.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/tmp/\n/vendor/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && DEVFLOW_VENDOR=1 manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: DEVFLOW_VENDOR=1 un-ignores /vendor/" \
  "no" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "install: DEVFLOW_VENDOR=1 keeps /tmp/" \
  "yes" "$(grep -qxF '/tmp/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
rm -rf "$WORK"

# Case C: no scaffolded .gitignore → no-op, no crash (exit 0).
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: missing .gitignore is a clean no-op" \
  "0" "$?"
assert_eq "install: no .gitignore created when absent" \
  "absent" "$([ -f "$WORK/.devflow/.gitignore" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case D: DEVFLOW_VENDOR=1 when /vendor/ is already absent → steady-state no-op,
# /tmp/ kept (symmetric to the thin-side idempotency check above).
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/tmp/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && DEVFLOW_VENDOR=1 manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: DEVFLOW_VENDOR=1 with /vendor/ already absent keeps it absent" \
  "no" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "install: DEVFLOW_VENDOR=1 steady-state keeps /tmp/" \
  "yes" "$(grep -qxF '/tmp/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
rm -rf "$WORK"

# Case E: DEVFLOW_VENDOR=1 when /vendor/ is the ONLY line (the empty-filter edge
# the grep-exit-1 handling exists for) → removed cleanly, file left empty, exit 0.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/vendor/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && DEVFLOW_VENDOR=1 manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: DEVFLOW_VENDOR=1 removes /vendor/ when it is the only line" "0" "$?"
assert_eq "install: only-line /vendor/ removal leaves no /vendor/" \
  "no" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
rm -rf "$WORK"

# ────────────────────────────────────────────────────────────────────────────
echo "no stale .claude/plugins/devflow reference in shipped cloud-tier files"
# ────────────────────────────────────────────────────────────────────────────
# Locks the invariant this relocation establishes: the runtime-vendored plugin
# lives at .devflow/vendor/devflow, so no workflow, composite action, or config
# schema may reference the old .claude/plugins/devflow path (a stale reference
# fails closed at runtime — "resolver not found" / wiped plugin). install.sh and
# the test file are not in the scan scope (it covers only `.github` +
# config.schema.json) — they legitimately name the old path (the prune migration
# that removes it, and these tests), and there is no exclusion filter to maintain.
# NB: no `xargs -r` — that flag is GNU-only (BSD/macOS xargs rejects it), and
# CONTRIBUTING bans GNU-only flags. The `git ls-files` input is always non-empty
# (.devflow/config.schema.json + the .github workflows are tracked), so the
# no-run-if-empty behavior `-r` provides is never needed here.
STALE=$(cd "$LIB/.." && git ls-files .github .devflow/config.schema.json \
  | xargs grep -lF '.claude/plugins/devflow' 2>/dev/null || true)
assert_eq "install: no shipped cloud-tier file references the old vendored path" \
  "" "$STALE"

# The generated marketplace.json `source` is the one path-bearing installer
# output with no other coverage; a heredoc typo reverting it would ship to fresh
# consumers uncaught. Assert it matches the relocated vendor destination.
assert_eq "install: marketplace.json source matches the vendored path" \
  "1" "$(grep -cF '"source": "./.devflow/vendor/devflow"' "$LIB/../install.sh")"

# ────────────────────────────────────────────────────────────────────────────
echo "workflow partition invariant"
# ────────────────────────────────────────────────────────────────────────────
# Every gate `if:` line that matches a /devflow: command trigger must ALSO
# negate @claude on that same line, so no comment can fire both a DevFlow
# workflow and Anthropic's claude.yml. Covers devflow.yml (review/pr-description)
# and devflow-implement.yml (/devflow:implement).
WF="$LIB/../.github/workflows"
for f in devflow devflow-implement; do
  bad="$(grep -nE "contains\((github\.event[^)]*),[[:space:]]*'/devflow:(review|pr-description|implement)'\)" "$WF/$f.yml" \
        | grep -v "@claude" || true)"
  assert_eq "partition: $f.yml /devflow triggers all negate @claude" "" "$bad"
done

# The label trigger is gone: neither workflow may listen on `labeled`.
for f in devflow devflow-implement; do
  bad="$(grep -nE "^[[:space:]]*types:.*labeled" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml has no labeled trigger" "" "$bad"
done

# Comment-only triggers: a /devflow:* phrase in an issue/PR DESCRIPTION must
# never start a run. Neither workflow may (a) listen on the `issues` event, nor
# (b) match the trigger phrase against an issue body/title in its gate `if:`.
# Only real comment/review bodies are valid trigger sources.
for f in devflow devflow-implement; do
  bad="$(grep -nE "^[[:space:]]*issues:[[:space:]]*$" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml does not listen on the issues event" "" "$bad"
  # No gate matching against issue.body / issue.title (those are descriptions).
  bad="$(grep -nE "contains\(github\.event\.issue\.(body|title)" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml gate never matches an issue body/title" "" "$bad"
  # TRIGGER_TEXT must be sourced only from comment/review bodies.
  bad="$(grep -nE "TRIGGER_TEXT:.*github\.event\.issue\.(body|title)" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml TRIGGER_TEXT excludes issue body/title" "" "$bad"
done

# Early-ack reaction must stay correctly wired in BOTH gate jobs. These guard
# the load-bearing properties that the react-to-trigger.sh unit tests above
# CANNOT see (they exercise the script in isolation): it must run only after
# authorization, the gate must hold the write scopes the POST needs, and it must
# be `bash`-invoked so it doesn't depend on the vendored copy's exec bit. Slice
# out just the gate job — `issues:/pull-requests: write` also appear on the
# heavy command/claude jobs, so a whole-file grep would not prove gate scoping.
gate_block() {
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inblock = ($0 ~ /^  gate:/) }
    inblock { print }
  ' "$1"
}
for f in devflow devflow-implement; do
  blk="$(gate_block "$WF/$f.yml")"
  # 1. Ack step is gated on resolver authorization — never reacts before should_run.
  guard="$(printf '%s\n' "$blk" | awk '/name: Acknowledge trigger/{f=1} f && /should_run ==/ {print "ok"; exit}')"
  assert_eq "react: $f.yml ack step gated on should_run" "ok" "$guard"
  # 2. Gate grants exactly the scopes the reactions POST needs.
  assert_eq "react: $f.yml gate grants issues:write" "1" \
    "$(printf '%s\n' "$blk" | grep -cE '^[[:space:]]+issues:[[:space:]]*write')"
  assert_eq "react: $f.yml gate grants pull-requests:write" "1" \
    "$(printf '%s\n' "$blk" | grep -cE '^[[:space:]]+pull-requests:[[:space:]]*write')"
  # 3. Invoked via `bash` (no exec-bit dependency on the vendored copy).
  bad="$(printf '%s\n' "$blk" | grep -nE 'run:.*react-to-trigger\.sh' | grep -v 'bash ' || true)"
  assert_eq "react: $f.yml invokes react-to-trigger.sh via bash" "" "$bad"
done

# ────────────────────────────────────────────────────────────────────────────
echo "devflow-review.yml first-ready gate invariant"
# ────────────────────────────────────────────────────────────────────────────
# The first-ready gate counts pre-existing `Devflow Review` check-runs to enforce
# auto-review-exactly-once. A skipped job still emits a `Devflow Review` check-run
# (conclusion: skipped) — from the dual pull_request/pull_request_target dedupe
# loser and from draft/synchronize deferrals — so both gate queries (head-SHA and
# commit-list backstop) MUST exclude `conclusion == "skipped"`, or the gate
# counts its own deferrals as "already ran" and the review never fires. The
# sibling synchronize cost-guard keeps its narrower `conclusion=="success"` filter
# (correct for that path); this guard asserts exactly two gate queries carry the
# skipped-exclusion form.
#
# The regexes tolerate optional whitespace around `==` / `!=` (` *==? *`) so a
# jq reformat of the workflow doesn't produce a false failure. The load-bearing
# protection is the bare-query guard below: it pins the actual issue-#32
# regression (a first-ready-gate select on the name alone, with no conclusion
# filter, that recounts skipped deferrals as "already ran") to zero occurrences.
REVIEW_WF="$WF/devflow-review.yml"
# (1) No first-ready-gate query may count check-runs unconditionally — a name-only
# select with nothing after it is exactly the issue-#32 bug.
bare_gate_query_count="$(grep -cE \
  'select\(\.name *== *"Devflow Review"\) *\|' \
  "$REVIEW_WF" || true)"
assert_eq "first-ready gate: no unfiltered Devflow Review check-run query" \
  "0" "$bare_gate_query_count"
# (2) Both gate queries (head-SHA + commit-list backstop) exclude skipped check-runs.
gate_skipped_filter_count="$(grep -cE \
  'select\(\.name *== *"Devflow Review" and \.conclusion *!= *"skipped"\)' \
  "$REVIEW_WF" || true)"
assert_eq "first-ready gate: both queries exclude conclusion==skipped" \
  "2" "$gate_skipped_filter_count"
# (3) The synchronize cost-guard must NOT be widened to != "skipped" — it stays
# scoped to conclusion=="success".
sync_success_filter_count="$(grep -cE \
  'select\(\.name *== *"Devflow Review" and \.conclusion *== *"success"\)' \
  "$REVIEW_WF" || true)"
assert_eq "synchronize cost-guard keeps conclusion==success filter" \
  "1" "$sync_success_filter_count"

# ────────────────────────────────────────────────────────────────────────────
echo "efficiency-trace.jq / efficiency-trace.sh"
# ────────────────────────────────────────────────────────────────────────────
# Per-run subagent effectiveness telemetry for /devflow:review-and-fix.
# Derivation is mechanical (jq); the wrapper validates inputs, reads the gating
# flag, and dispatches per mode. Fixtures exercise: 4-way verdict derivation,
# the per-iteration marginal-yield line, flag-off → no writes, and graceful
# degradation when phase3_dispatched is absent.
ET_DIR="$(mktemp -d)"
# Iter 1: a unique-effective applied finding (corroboration 1), a corroborating
# applied finding (corroboration 2), one dispatched-but-silent agent (null), and
# a mix of lite/agent checklist items. 4 fixes applied.
cat > "$ET_DIR/iter-1.json" <<'EOF'
{
  "iter": 1,
  "checklist": [
    {"id":"VC-1","verification_mode":"lite","verdict":"PASS"},
    {"id":"VC-2","verification_mode":"lite","verdict":"FAIL"},
    {"id":"VC-3","verification_mode":"agent","verdict":"PASS"}
  ],
  "phase3_dispatched": ["pr-review-toolkit:code-reviewer","pr-review-toolkit:silent-failure-hunter","pr-review-toolkit:comment-analyzer"],
  "phase3_findings": [
    {"agent":"pr-review-toolkit:code-reviewer","corroboration_count":1,"fix_decision":"applied"},
    {"agent":"pr-review-toolkit:silent-failure-hunter","corroboration_count":2,"fix_decision":"applied"}
  ],
  "convergence_inputs": {"fixes_applied": 4},
  "telemetry": {"phase_3": {"calls": 3, "tokens": 48000, "wall_clock_s": 180}}
}
EOF
# Iter 2: zero fixes (marginal-yield), one pushed-back finding (noise), one
# dispatched-but-silent agent (null).
cat > "$ET_DIR/iter-2.json" <<'EOF'
{
  "iter": 2,
  "checklist": [],
  "phase3_dispatched": ["pr-review-toolkit:code-reviewer","pr-review-toolkit:comment-analyzer"],
  "phase3_findings": [
    {"agent":"pr-review-toolkit:code-reviewer","corroboration_count":1,"fix_decision":"pushed_back"}
  ],
  "convergence_inputs": {"fixes_applied": 0},
  "telemetry": {"phase_3": {"calls": 2, "tokens": 12000, "wall_clock_s": 60}}
}
EOF

ET_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
ET_verdict() { echo "$ET_REC" | jq -r --argjson i "$1" --arg a "$2" '.per_iteration[] | select(.iter==$i) | .agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et: applied + corroboration<2 → unique-effective" "unique-effective" "$(ET_verdict 1 'pr-review-toolkit:code-reviewer')"
assert_eq "et: applied + corroboration>=2 → corroborating"   "corroborating"    "$(ET_verdict 1 'pr-review-toolkit:silent-failure-hunter')"
assert_eq "et: dispatched but silent → null"                 "null"             "$(ET_verdict 1 'pr-review-toolkit:comment-analyzer')"
assert_eq "et: only pushed_back finding → noise"             "noise"            "$(ET_verdict 2 'pr-review-toolkit:code-reviewer')"
assert_eq "et: roster-minus-findings null on a LATER iteration" "null"          "$(ET_verdict 2 'pr-review-toolkit:comment-analyzer')"
# The silent-agent verdict must be JSON null, not the string "null" — so a
# cross-run analyzer can use idiomatic `select(.verdict == null)`. `jq -r`
# renders both as "null", so assert the JSON type explicitly.
ET_verdict_type() { echo "$ET_REC" | jq -r --argjson i "$1" --arg a "$2" '.per_iteration[] | select(.iter==$i) | .agent_verdicts[] | select(.agent==$a) | .verdict | type'; }
assert_eq "et: silent-agent verdict is JSON null, not string" "null" "$(ET_verdict_type 1 'pr-review-toolkit:comment-analyzer')"
assert_eq "et: record carries cost telemetry forward (iter1 phase_3 tokens)" "48000" \
  "$(echo "$ET_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases.phase_3.tokens')"
assert_eq "et: record schema_version=1" "1" "$(echo "$ET_REC" | jq -r '.schema_version')"
assert_eq "et: cut_candidate_min_dispatch carried into record (default 3)" "3" \
  "$(echo "$ET_REC" | jq -r '.cut_candidate_min_dispatch')"
assert_eq "et: checklist split lite=2" "2" "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .checklist_lite_count')"
assert_eq "et: checklist split agent=1" "1" "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .checklist_agent_count')"

# diff_profile + verification posture: the Phase 0.5 classification is carried
# into the record (so the cross-run analyzer can segment by diff shape), and the
# orchestrator's no-subagent cost decision is logged as an explicit posture
# rather than a bare "0 verifiers".
ET_PROF="$(mktemp -d)"
# iter-1: engine_self_modifying diff, verification done via lite probes only (no agents).
cat > "$ET_PROF/iter-1.json" <<'EOF'
{"iter":1,"diff_profile":{"small_diff":false,"config_only":false,"has_new_types":false,"engine_self_modifying":true,"checklist_skipped":null},
"checklist":[{"verification_mode":"lite","verdict":"PASS"},{"verification_mode":"lite","verdict":"PASS"}],
"phase3_dispatched":["pr-review-toolkit:code-reviewer"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
# iter-2: small_diff+config_only, Phase 0.5 intentionally skipped the checklist.
cat > "$ET_PROF/iter-2.json" <<'EOF'
{"iter":2,"diff_profile":{"small_diff":true,"config_only":true,"has_new_types":false,"engine_self_modifying":false,"checklist_skipped":"intentional"},
"checklist":[],"phase3_dispatched":["pr-review-toolkit:code-reviewer"],
"phase3_findings":[{"agent":"pr-review-toolkit:code-reviewer","corroboration_count":1,"fix_decision":"applied"}],
"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_PROF_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PROF" --slug pr-15 --mode record)"
assert_eq "et: diff_profile carried into record (engine_self_modifying)" "true" \
  "$(echo "$ET_PROF_REC" | jq -r '.per_iteration[] | select(.iter==1) | .diff_profile.engine_self_modifying')"
assert_eq "et: lite-only verification posture (no subagents dispatched)" "lite-only" \
  "$(echo "$ET_PROF_REC" | jq -r '.per_iteration[] | select(.iter==1) | .verification_posture')"
assert_eq "et: Phase 0.5 intentional skip → skipped-intentional posture" "skipped-intentional" \
  "$(echo "$ET_PROF_REC" | jq -r '.per_iteration[] | select(.iter==2) | .verification_posture')"
ET_PROF_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PROF" --slug pr-15 --mode trace)"
assert_eq "et: trace logs the no-subagent decision (lite-only line)" "true" \
  "$(echo "$ET_PROF_TRACE" | grep -q 'without dispatching verifier subagents' && echo true || echo false)"
assert_eq "et: trace logs intentional Phase 0.5 skip" "true" \
  "$(echo "$ET_PROF_TRACE" | grep -q 'skipped by Phase 0.5' && echo true || echo false)"
assert_eq "et: trace renders diff profile line" "true" \
  "$(echo "$ET_PROF_TRACE" | grep -q 'Diff profile: engine_self_modifying' && echo true || echo false)"
# Absent diff_profile degrades gracefully: posture falls back to raw counts, label "not recorded".
ET_NOPROF="$(mktemp -d)"
cat > "$ET_NOPROF/iter-1.json" <<'EOF'
{"iter":1,"checklist":[{"verification_mode":"agent","verdict":"PASS"}],"phase3_dispatched":["a"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_NOPROF_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_NOPROF" --slug s --mode record)"
assert_eq "et: absent diff_profile → null in record" "null" \
  "$(echo "$ET_NOPROF_REC" | jq -r '.per_iteration[0].diff_profile')"
assert_eq "et: absent diff_profile → posture from raw counts (agent-only)" "agent-only" \
  "$(echo "$ET_NOPROF_REC" | jq -r '.per_iteration[0].verification_posture')"
rm -rf "$ET_PROF" "$ET_NOPROF"

# Engine-PR analyzer gating (issue #52): the gating change is prose in
# skills/review/SKILL.md; its observable contract is the phase3_dispatched
# roster the orchestrator writes. Assert the roster flows through the trace so
# a gated-out type/test analyzer is absent on an engine-self-modifying diff with
# nothing for them to analyze, and present when the engine PR adds testable code.
ET_GATE="$(mktemp -d)"
# iter-1: engine_self_modifying, has_new_types=false, no test/code-logic changes
# → only the four always-on agents dispatched; type/test analyzers gated out.
cat > "$ET_GATE/iter-1.json" <<'EOF'
{"iter":1,"diff_profile":{"small_diff":false,"config_only":true,"has_new_types":false,"engine_self_modifying":true,"checklist_skipped":null},
"checklist":[{"verification_mode":"lite","verdict":"PASS"}],
"phase3_dispatched":["pr-review-toolkit:code-reviewer","pr-review-toolkit:silent-failure-hunter","pr-review-toolkit:comment-analyzer","superpowers:requesting-code-review"],
"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":{"phase_3":{"calls":4,"tokens":40000,"wall_clock_s":120}}}
EOF
# iter-2: engine_self_modifying diff that adds testable code logic → pr-test-analyzer
# is dispatched (test-relevance predicate branch 2); type-design still gated out.
cat > "$ET_GATE/iter-2.json" <<'EOF'
{"iter":2,"diff_profile":{"small_diff":false,"config_only":false,"has_new_types":false,"engine_self_modifying":true,"checklist_skipped":null},
"checklist":[{"verification_mode":"agent","verdict":"PASS"}],
"phase3_dispatched":["pr-review-toolkit:code-reviewer","pr-review-toolkit:silent-failure-hunter","pr-review-toolkit:comment-analyzer","superpowers:requesting-code-review","pr-review-toolkit:pr-test-analyzer"],
"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":{"phase_3":{"calls":5,"tokens":52000,"wall_clock_s":160}}}
EOF
ET_GATE_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_GATE" --slug "pr-15" --mode record)"
# Exact array-membership (jq `index`), not substring grep — so an exclusion
# assertion can't be fooled by a longer agent id that merely contains the name.
# These assert the trace's roster PASSTHROUGH for the rosters the gating prose
# produces; the gating decision itself is LLM-prose in skills/review/SKILL.md
# (not harness-reachable), so this guards that a gated roster survives the trace.
ET_has() { echo "$ET_GATE_REC" | jq -r --argjson i "$1" --arg a "$2" '.per_iteration[] | select(.iter==$i) | (.phase3_dispatched | index($a) != null)'; }
assert_eq "et(#52): engine-PR no-types/no-tests roster passthrough excludes type-design-analyzer" "false" \
  "$(ET_has 1 'pr-review-toolkit:type-design-analyzer')"
assert_eq "et(#52): engine-PR no-types/no-tests roster passthrough excludes pr-test-analyzer" "false" \
  "$(ET_has 1 'pr-review-toolkit:pr-test-analyzer')"
assert_eq "et(#52): engine-PR no-types/no-tests dispatched count = 4 always-on" "4" \
  "$(echo "$ET_GATE_REC" | jq -r '.per_iteration[] | select(.iter==1) | .phase3_dispatched_count')"
assert_eq "et(#52): engine-PR adding testable code roster passthrough includes pr-test-analyzer" "true" \
  "$(ET_has 2 'pr-review-toolkit:pr-test-analyzer')"
assert_eq "et(#52): engine-PR adding testable code still excludes type-design-analyzer" "false" \
  "$(ET_has 2 'pr-review-toolkit:type-design-analyzer')"
rm -rf "$ET_GATE"

# none-recorded posture remains reachable for the genuine degraded case the
# writer-gap-closing prose now leans on: Phase 1+2 ran (checklist_skipped null)
# but the checklist array is empty / no items recorded. This is the "real
# regression worth investigating" branch — lock it so it can't silently change.
ET_NR="$(mktemp -d)"
cat > "$ET_NR/iter-1.json" <<'EOF'
{"iter":1,"diff_profile":{"small_diff":false,"config_only":false,"has_new_types":false,"engine_self_modifying":false,"checklist_skipped":null},
"checklist":[],"phase3_dispatched":["pr-review-toolkit:code-reviewer"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_NR_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_NR" --slug "pr-15" --mode record)"
assert_eq "et(#52): Phase 1+2 ran but zero checklist items → none-recorded (genuine gap)" "none-recorded" \
  "$(echo "$ET_NR_REC" | jq -r '.per_iteration[0].verification_posture')"
rm -rf "$ET_NR"

# Partial telemetry resilience: a workpad whose telemetry block has one phase
# present (others absent) still yields a non-null telemetry[].phases — mirroring
# the writer contract that a missing per-source token never nulls the whole block.
ET_PT="$(mktemp -d)"
cat > "$ET_PT/iter-1.json" <<'EOF'
{"iter":1,"checklist":[{"verification_mode":"lite","verdict":"PASS"}],"phase3_dispatched":["a"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":{"phase_3":{"calls":1,"wall_clock_s":10}}}
EOF
ET_PT_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PT" --slug "pr-15" --mode record)"
assert_eq "et(#52): partial telemetry (one phase, no tokens) → phases non-null" "false" \
  "$(echo "$ET_PT_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases' | grep -q '^null$' && echo true || echo false)"
assert_eq "et(#52): partial telemetry preserves the present phase's calls" "1" \
  "$(echo "$ET_PT_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases.phase_3.calls')"
rm -rf "$ET_PT"

# Executable-bit guard (corroborated review finding): direct invocation of the
# helper depends on lib/efficiency-trace.sh keeping its committed +x bit through
# vendoring. The harness invokes it `bash "$LIB/..."`, which masks a lost bit, so
# assert the committed mode is 100755 — a lost bit fails CI rather than silently
# disabling headless telemetry in production.
assert_eq "et(#52): lib/efficiency-trace.sh committed executable (100755)" "100755" \
  "$(cd "$LIB/.." && git ls-files -s lib/efficiency-trace.sh | cut -d' ' -f1)"

# ── Review-mode derivation (issue #55) ──────────────────────────────────────
# Standalone /devflow:review never applies a fix, so its records carry
# `contributed_to_verdict` (bool) per finding instead of `fix_decision`.
# verdict_for selects the review-mode branch off the run-level source:"review"
# (not per-finding field presence — see the ET_RMIX omitted-field case below):
# contributed (corr<2)→unique-effective, contributed (corr>=2)→corroborating,
# only-demoted→noise, silent→null. And the record carries source:"review".
ET_REV="$(mktemp -d)"
cat > "$ET_REV/iter-1.json" <<'EOF'
{
  "iter": 1,
  "source": "review",
  "checklist": [{"verification_mode":"lite","verdict":"PASS"},{"verification_mode":"agent","verdict":"FAIL"}],
  "phase3_dispatched": ["rev-unique","rev-corrob","rev-demoted","rev-silent"],
  "phase3_findings": [
    {"agent":"rev-unique","corroboration_count":1,"contributed_to_verdict":true},
    {"agent":"rev-corrob","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"rev-demoted","corroboration_count":1,"contributed_to_verdict":false}
  ],
  "convergence_inputs": {"fixes_applied": 0},
  "telemetry": {"phase_3": {"calls": 4, "tokens": 30000, "wall_clock_s": 90}}
}
EOF
ET_REV_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_REV" --slug "pr-99" --mode record)"
ET_rv() { echo "$ET_REV_REC" | jq -r --arg a "$1" '.per_iteration[0].agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et(#55): review-mode contributed + corr<2 → unique-effective" "unique-effective" "$(ET_rv 'rev-unique')"
assert_eq "et(#55): review-mode contributed + corr>=2 → corroborating"    "corroborating"    "$(ET_rv 'rev-corrob')"
assert_eq "et(#55): review-mode only-demoted finding → noise"             "noise"            "$(ET_rv 'rev-demoted')"
assert_eq "et(#55): review-mode dispatched-but-silent → null"             "null"             "$(ET_rv 'rev-silent')"
assert_eq "et(#55): review-mode silent verdict is JSON null (not string)" "null" \
  "$(echo "$ET_REV_REC" | jq -r '.per_iteration[0].agent_verdicts[] | select(.agent=="rev-silent") | .verdict | type')"
assert_eq "et(#55): record carries source: review" "review" \
  "$(echo "$ET_REV_REC" | jq -r '.source')"
rm -rf "$ET_REV"

# A review-and-fix record (fix_decision, no contributed_to_verdict) is unaffected
# by the review-mode branch and defaults source to review-and-fix.
ET_RAF="$(mktemp -d)"
cat > "$ET_RAF/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":["a"],
"phase3_findings":[{"agent":"a","corroboration_count":1,"fix_decision":"applied"}],
"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_RAF_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RAF" --slug "pr-1" --mode record)"
assert_eq "et(#55): review-and-fix record still classifies off fix_decision (applied→unique-effective)" "unique-effective" \
  "$(echo "$ET_RAF_REC" | jq -r '.per_iteration[0].agent_verdicts[] | select(.agent=="a") | .verdict')"
assert_eq "et(#55): absent source defaults to review-and-fix" "review-and-fix" \
  "$(echo "$ET_RAF_REC" | jq -r '.source')"
rm -rf "$ET_RAF"

# Review-mode per-agent aggregation (issue #55 review hardening): the verdict is
# keyed off the run-level source ("review"), not per-finding field presence, so
# these stress the branch ordering and the omitted-field → noise path that the
# one-finding-per-agent fixtures above don't reach.
ET_RMIX="$(mktemp -d)"
cat > "$ET_RMIX/iter-1.json" <<'EOF'
{
  "iter": 1,
  "source": "review",
  "checklist": [],
  "phase3_dispatched": ["mix-unique","mix-corrob","omit-demoted","mixcorr","allcorr","str-true"],
  "phase3_findings": [
    {"agent":"mix-unique","corroboration_count":1,"contributed_to_verdict":true},
    {"agent":"mix-unique","corroboration_count":1,"contributed_to_verdict":false},
    {"agent":"mix-corrob","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"mix-corrob","corroboration_count":1,"contributed_to_verdict":false},
    {"agent":"omit-demoted","corroboration_count":1},
    {"agent":"mixcorr","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"mixcorr","corroboration_count":1,"contributed_to_verdict":true},
    {"agent":"allcorr","corroboration_count":2,"contributed_to_verdict":true},
    {"agent":"allcorr","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"str-true","corroboration_count":1,"contributed_to_verdict":"true"}
  ],
  "convergence_inputs": {"fixes_applied": 0},
  "telemetry": null
}
EOF
ET_RMIX_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RMIX" --slug "pr-99" --mode record)"
ET_mv() { echo "$ET_RMIX_REC" | jq -r --arg a "$1" '.per_iteration[0].agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et(#55): contributing finding wins over a co-located demoted one (corr<2)" "unique-effective" "$(ET_mv 'mix-unique')"
assert_eq "et(#55): contributing finding wins over a co-located demoted one (corr>=2)" "corroborating" "$(ET_mv 'mix-corrob')"
# The regression test for the corroborated review finding: a demoted finding that
# OMITS contributed_to_verdict must still classify noise (not null) — the agent
# raised something, it just didn't contribute.
assert_eq "et(#55): omitted contributed_to_verdict on a raised finding → noise (not null)" "noise" "$(ET_mv 'omit-demoted')"
# Mixed corroboration within contributing findings: any unique (corr<2) → unique-effective.
assert_eq "et(#55): mixed corroboration among contributing findings → unique-effective" "unique-effective" "$(ET_mv 'mixcorr')"
# 2+ contributing findings, ALL corroborated (corr>=2) → stays corroborating (no
# unique discoverer among them). Guards the precedence boundary the single-finding
# rev-corrob fixture above can't reach.
assert_eq "et(#55): 2+ contributing findings all corr>=2 → corroborating" "corroborating" "$(ET_mv 'allcorr')"
# Malformed contributed_to_verdict (a stringified "true" from an LLM-authored
# record) is NOT truthy: the `== true` gate is strict, so the agent raised a
# finding that didn't contribute → noise (not unique-effective, not null). Pins
# the deliberate strict-boolean contract documented in verdict_for.
assert_eq "et(#55): stringified \"true\" contributed_to_verdict → noise (strict == true gate)" "noise" "$(ET_mv 'str-true')"
# Review-mode verdicts must also surface in the --mode trace Markdown (the live-
# comment surface), not just the --mode record JSON exercised above.
ET_RMIX_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RMIX" --slug "pr-99" --mode trace)"
assert_eq "et(#55): review-mode verdicts render in --mode trace Markdown" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -qiE 'corroborating|unique-effective' && echo true || echo false)"
# Review-mode render (issue #56 review): the fixes-oriented summary/warning lines
# are adapted for review mode — show the verdict-contribution signal, NOT the
# misleading "Fixes applied: 0" / fix-based "added nothing" that would contradict
# the unique-effective/corroborating verdicts a healthy review prints.
assert_eq "et(#56): review-mode trace shows the verdict-contribution signal" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -q 'Effectiveness signal: verdict contribution' && echo true || echo false)"
assert_eq "et(#56): review-mode trace omits the fixes-oriented 'Fixes applied' line" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -q 'Fixes applied' && echo false || echo true)"
assert_eq "et(#56): review-mode trace (agents contributed) omits the fix-based 'added nothing' warning" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -q 'added nothing' && echo false || echo true)"
rm -rf "$ET_RMIX"

# Multi-iteration run-level source resolution: iter-1 carries no source, iter-2
# carries "review" → the run-level source is "review" (first non-null), and each
# iteration still classifies off its own source.
ET_RMI="$(mktemp -d)"
cat > "$ET_RMI/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":["a"],"phase3_findings":[{"agent":"a","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
cat > "$ET_RMI/iter-2.json" <<'EOF'
{"iter":2,"source":"review","checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"contributed_to_verdict":true}],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_RMI_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RMI" --slug "pr-99" --mode record)"
assert_eq "et(#55): run-level source is first non-null across iters (review)" "review" \
  "$(echo "$ET_RMI_REC" | jq -r '.source')"
assert_eq "et(#55): iter-1 (fix_decision, no source) classifies off its own shape" "unique-effective" \
  "$(echo "$ET_RMI_REC" | jq -r '.per_iteration[] | select(.iter==1) | .agent_verdicts[0].verdict')"
assert_eq "et(#55): iter-2 (source review) classifies review-mode" "unique-effective" \
  "$(echo "$ET_RMI_REC" | jq -r '.per_iteration[] | select(.iter==2) | .agent_verdicts[0].verdict')"
rm -rf "$ET_RMI"

# Mixed-source future-proofing warning (issue #55 review hardening): a run whose
# iterations carry genuinely divergent `source` values is not currently produced,
# but if it ever is, the wrapper warns (best-effort, never aborts) — the record's
# run-level source collapses to the first non-null and would otherwise silently
# mislabel the run. No fixture exercised this guard before.
ET_MIXSRC="$(mktemp -d)"
cat > "$ET_MIXSRC/iter-1.json" <<'EOF'
{"iter":1,"source":"review","checklist":[],"phase3_dispatched":["a"],"phase3_findings":[{"agent":"a","corroboration_count":1,"contributed_to_verdict":true}],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
cat > "$ET_MIXSRC/iter-2.json" <<'EOF'
{"iter":2,"source":"review-and-fix","checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_MIXSRC_ERR="$(mktemp)"
ET_MIXSRC_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_MIXSRC" --slug "pr-99" --mode record 2>"$ET_MIXSRC_ERR")"; ET_MIXSRC_RC=$?
assert_eq "et(#55): mixed explicit sources → wrapper still exits 0 (best-effort)" "0" "$ET_MIXSRC_RC"
assert_eq "et(#55): mixed explicit sources (review + review-and-fix) → warns" "true" \
  "$(grep -q "::warning::.*mixed 'source'" "$ET_MIXSRC_ERR" && echo true || echo false)"
assert_eq "et(#55): mixed-source record still collapses run-level source to first non-null (review)" "review" \
  "$(echo "$ET_MIXSRC_REC" | jq -r '.source')"
# A `review` iter mixed with a source-LESS iter must ALSO warn: the absent source
# is counted as the run-level default (review-and-fix), so the run is genuinely
# mixed even though one iter omits the field. Guards the `.source // "review-and-fix"`
# counting — a bare `.source // empty` would drop the absent iter and stay silent.
cat > "$ET_MIXSRC/iter-2.json" <<'EOF'
{"iter":2,"checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_MIXSRC_ERR2="$(mktemp)"
bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_MIXSRC" --slug "pr-99" --mode record >/dev/null 2>"$ET_MIXSRC_ERR2"
assert_eq "et(#55): review + source-less iter → also warns (absent counts as default)" "true" \
  "$(grep -q "::warning::.*mixed 'source'" "$ET_MIXSRC_ERR2" && echo true || echo false)"
rm -rf "$ET_MIXSRC"; rm -f "$ET_MIXSRC_ERR" "$ET_MIXSRC_ERR2"

# Regression guard for the new counting: a uniform single-source run must NOT warn.
# Two source-less iters both default to review-and-fix → one distinct value → silent
# (this is the common /devflow:review-and-fix loop, which must stay warning-free).
ET_SAMESRC="$(mktemp -d)"
cat > "$ET_SAMESRC/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":["a"],"phase3_findings":[{"agent":"a","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
cat > "$ET_SAMESRC/iter-2.json" <<'EOF'
{"iter":2,"checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_SAMESRC_ERR="$(mktemp)"
bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_SAMESRC" --slug "pr-1" --mode record >/dev/null 2>"$ET_SAMESRC_ERR"
assert_eq "et(#55): uniform source-less run → does NOT warn" "false" \
  "$(grep -q "::warning::.*mixed 'source'" "$ET_SAMESRC_ERR" && echo true || echo false)"
rm -rf "$ET_SAMESRC"; rm -f "$ET_SAMESRC_ERR"

# Populated checklist/telemetry writer gap closed (issue #52): a workpad where
# Phase 1+2 ran yields a real lite/agent split, a non-none-recorded posture, and
# non-null telemetry[].phases — i.e. none-recorded/null phases now signal genuine
# degradation only, never a normal full-engine run.
assert_eq "et(#52): populated checklist → posture is not none-recorded" "false" \
  "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .verification_posture' | grep -q 'none-recorded' && echo true || echo false)"
assert_eq "et(#52): populated checklist → posture mixed (lite+agent)" "mixed" \
  "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .verification_posture')"
assert_eq "et(#52): populated telemetry block → telemetry[].phases non-null" "false" \
  "$(echo "$ET_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases' | grep -q '^null$' && echo true || echo false)"

# Marginal-yield line: iter 2 applied 0 fixes → trace flags "added nothing".
ET_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode trace)"
assert_eq "et: marginal-yield line for zero-fix iteration" "true" \
  "$(echo "$ET_TRACE" | grep -q 'Marginal yield: this iteration applied 0 fixes' && echo true || echo false)"
assert_eq "et: trace shows dispatched count" "true" \
  "$(echo "$ET_TRACE" | grep -q 'Phase 3 agents dispatched: 3' && echo true || echo false)"

# Flag-off → no output in either mode (so the SKILL.md write produces no file).
ET_CFG="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_telemetry_enabled":false}}' > "$ET_CFG"
ET_OFF_REC="$(DEVFLOW_CONFIG_FILE="$ET_CFG" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
ET_OFF_TRACE="$(DEVFLOW_CONFIG_FILE="$ET_CFG" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode trace)"
assert_eq "et: flag-off → record empty" "" "$ET_OFF_REC"
assert_eq "et: flag-off → trace empty"  "" "$ET_OFF_TRACE"

# Graceful degradation: a workpad WITHOUT phase3_dispatched still classifies the
# agents that appear in phase3_findings; the trace flags the missing roster.
ET_DEG="$(mktemp -d)"
cat > "$ET_DEG/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_findings":[{"agent":"pr-review-toolkit:code-reviewer","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_DEG_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DEG" --slug "branch-x" --mode record)"
assert_eq "et: degraded (no phase3_dispatched) still classifies finding agent" "unique-effective" \
  "$(echo "$ET_DEG_REC" | jq -r '.per_iteration[0].agent_verdicts[] | select(.agent=="pr-review-toolkit:code-reviewer") | .verdict')"
assert_eq "et: degraded dispatched_count=0 (roster absent)" "0" \
  "$(echo "$ET_DEG_REC" | jq -r '.per_iteration[0].phase3_dispatched_count')"
ET_DEG_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DEG" --slug "branch-x" --mode trace)"
assert_eq "et: degraded trace flags absent phase3_dispatched" "true" \
  "$(echo "$ET_DEG_TRACE" | grep -q 'absent.*null agents (dispatched but silent) cannot be shown' && echo true || echo false)"

# Present-but-empty roster ("phase3_dispatched": []) is NOT "absent" — the
# degradation warning must not fire (regression guard for has() vs length>0).
ET_EMPTYROSTER="$(mktemp -d)"
cat > "$ET_EMPTYROSTER/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":[],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_ER_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_EMPTYROSTER" --slug "pr-15" --mode trace)"
assert_eq "et: empty-but-present roster does NOT flag 'absent'" "false" \
  "$(echo "$ET_ER_TRACE" | grep -q 'null agents (dispatched but silent) cannot be shown' && echo true || echo false)"
rm -rf "$ET_EMPTYROSTER"

# A valid-but-non-object workpad (stray array) is skipped, not crashed on
# (best-effort never-abort contract). The wrapper must still exit 0.
ET_BADSHAPE="$(mktemp -d)"
printf '[1,2,3]' > "$ET_BADSHAPE/iter-1.json"
ET_BS_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_BADSHAPE" --slug "pr-15" --mode trace 2>/dev/null)"; ET_BS_RC=$?
assert_eq "et: non-object workpad → wrapper exits 0 (never aborts)" "0" "$ET_BS_RC"
assert_eq "et: non-object workpad → degrades to unavailable notice" "true" \
  "$(echo "$ET_BS_TRACE" | grep -q 'effectiveness trace unavailable' && echo true || echo false)"
rm -rf "$ET_BADSHAPE"

# No readable workpads → trace degrades to a one-line notice, never errors.
ET_EMPTY="$(mktemp -d)"
ET_EMPTY_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_EMPTY" --slug "branch-x" --mode trace)"
assert_eq "et: empty workpad dir → graceful notice" "true" \
  "$(echo "$ET_EMPTY_TRACE" | grep -q 'effectiveness trace unavailable' && echo true || echo false)"
# record mode with zero readable iterations emits NOTHING (not a contentless
# skeleton) so the caller's `[ -s ]` guard removes the 0-byte file — symmetric
# with the flag-off contract.
ET_EMPTY_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_EMPTY" --slug "branch-x" --mode record)"
assert_eq "et: zero-iteration record emits empty (no skeleton)" "" "$ET_EMPTY_REC"

# Verdict-precedence + branch coverage on a single mixed fixture. Each agent
# below isolates one path through verdict_for that the happy-path fixtures miss.
ET_PREC="$(mktemp -d)"
cat > "$ET_PREC/iter-1.json" <<'EOF'
{
  "iter": 1,
  "checklist": [],
  "phase3_dispatched": ["agent-mixed-unique","agent-mixed-corr","agent-advisory","agent-deferred","agent-nocorr"],
  "phase3_findings": [
    {"agent":"agent-mixed-unique","corroboration_count":1,"fix_decision":"applied"},
    {"agent":"agent-mixed-unique","corroboration_count":1,"fix_decision":"pushed_back"},
    {"agent":"agent-mixed-corr","corroboration_count":3,"fix_decision":"applied"},
    {"agent":"agent-mixed-corr","corroboration_count":1,"fix_decision":"advisory"},
    {"agent":"agent-advisory","corroboration_count":1,"fix_decision":"advisory"},
    {"agent":"agent-deferred","corroboration_count":1,"fix_decision":"deferred"},
    {"agent":"agent-nocorr","fix_decision":"applied"}
  ],
  "convergence_inputs": {"fixes_applied": 3},
  "telemetry": null
}
EOF
ET_PREC_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PREC" --slug "pr-15" --mode record)"
ET_pv() { echo "$ET_PREC_REC" | jq -r --arg a "$1" '.per_iteration[0].agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et: precedence applied(corr1)+pushed_back → unique-effective" "unique-effective" "$(ET_pv 'agent-mixed-unique')"
assert_eq "et: precedence applied(corr3)+advisory → corroborating (applied dominates noise)" "corroborating" "$(ET_pv 'agent-mixed-corr')"
assert_eq "et: advisory-only finding → noise" "noise" "$(ET_pv 'agent-advisory')"
assert_eq "et: deferred-only finding → null (not noise)" "null" "$(ET_pv 'agent-deferred')"
assert_eq "et: applied with missing corroboration_count → unique-effective (// 1 default)" "unique-effective" "$(ET_pv 'agent-nocorr')"
rm -rf "$ET_PREC"

# THRESHOLD: a valid custom integer is carried into the record; a non-numeric
# operator value falls back to the default 3 WITHOUT aborting the wrapper.
ET_TCFG="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_cut_candidate_min_dispatch":7}}' > "$ET_TCFG"
ET_T7="$(DEVFLOW_CONFIG_FILE="$ET_TCFG" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
assert_eq "et: custom threshold 7 carried into record" "7" "$(echo "$ET_T7" | jq -r '.cut_candidate_min_dispatch')"
ET_TBAD="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_cut_candidate_min_dispatch":"abc"}}' > "$ET_TBAD"
ET_TB="$(DEVFLOW_CONFIG_FILE="$ET_TBAD" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record 2>/dev/null)"; ET_TB_RC=$?
assert_eq "et: non-numeric threshold → wrapper still exits 0" "0" "$ET_TB_RC"
assert_eq "et: non-numeric threshold → falls back to 3 in record" "3" "$(echo "$ET_TB" | jq -r '.cut_candidate_min_dispatch')"
# A below-minimum value (0) is clamped to the default 3 (schema declares minimum:1).
ET_TZERO="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_cut_candidate_min_dispatch":0}}' > "$ET_TZERO"
ET_TZ="$(DEVFLOW_CONFIG_FILE="$ET_TZERO" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
assert_eq "et: threshold 0 (below schema minimum:1) → clamped to 3" "3" "$(echo "$ET_TZ" | jq -r '.cut_candidate_min_dispatch')"
rm -f "$ET_TCFG" "$ET_TBAD" "$ET_TZERO"

# CLI contract: an invalid --mode is rejected with exit 2 (protects SKILL.md's
# dependence on the trace/record flag names).
bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode bogus >/dev/null 2>&1; ET_MODE_RC=$?
assert_eq "et: invalid --mode → exit 2" "2" "$ET_MODE_RC"

rm -rf "$ET_DIR" "$ET_DEG" "$ET_EMPTY"; rm -f "$ET_CFG"

# ────────────────────────────────────────────────────────────────────────────
echo "devflow-runner.yml: opt-in environment provisioning (issues #18, #21)"
# ────────────────────────────────────────────────────────────────────────────
# The automated reviewer gains a build environment + build-tool allowlist ONLY
# when the TRUSTED base config sets devflow_runner.provision_env: true. These
# assertions pin the load-bearing invariants: (1) provisioning is gated on the
# base-ref flag, (2) the build allowlist is appended ONLY under that guard so
# the default profile stays byte-for-byte read-only, (3) both the flag and the
# setup block are sourced from the base ref (never the PR head) so a PR cannot
# enable provisioning or inject install commands into the write-token job.
RUNNER="$LIB/../.github/workflows/devflow-runner.yml"

# The read-only base profile line must NOT contain ANY of the 8 build tools —
# this is the "byte-for-byte read-only when disabled" guarantee. Check all eight
# (not just npm): a regression that moved a less-npm-shaped token like
# Bash(make:*) or Bash(php:*) onto the base line would slip a single-tool grep
# while breaking the security invariant. (The build tokens live only on the
# separate, PROVISION_ENV-guarded append line below.)
assert_eq "provision: read-only base profile has no build tools (all 8)" "0" \
  "$(grep "TOOLS='Read,Glob,Grep" "$RUNNER" \
     | grep -cE 'Bash\((npm|npx|node|yarn|pnpm|composer|php|make):\*\)' || true)"

# Issue #21: the build append is now the FREEFORM devflow_runner.allowed_tools
# list (read from the trusted base ref), not the old hard-coded npm…make set.
# (1) The fixed 8-tool append line must be GONE — listing build tools is now the
# adopter's config job, language-agnostic.
# Fixed-string match (-F): the literal contains `$TOOLS` and `(`/`)`/`*`; under a
# strict-POSIX/ugrep `grep` a mid-pattern `$` would anchor and the line would
# silently not match. -F keeps it portable.
assert_eq "provision: hard-coded npm…make build append removed" "0" \
  "$(grep -cF 'TOOLS="$TOOLS,Bash(npm:*),Bash(npx:*),Bash(node:*),Bash(yarn:*),Bash(pnpm:*),Bash(composer:*),Bash(php:*),Bash(make:*)"' "$RUNNER" || true)"

# (2) baseprovision emits runner_tools from the TRUSTED base ref ($BASE_JSON),
# joined to a comma string — the same trust channel as provision_env.
assert_eq "provision: runner_tools read from base config (BASE_JSON)" "1" \
  "$(grep -cF '.devflow_runner.allowed_tools // [] | map(strings) | join(",")' "$RUNNER" || true)"
assert_eq "provision: runner_tools written to GITHUB_OUTPUT (heredoc)" "1" \
  "$(grep -cF "printf 'runner_tools<<%s" "$RUNNER" || true)"
# The runner_tools value goes through a heredoc (not a single-line key=value
# echo), so a newline in a hand-edited base allowed_tools entry can't truncate
# the value or inject further step outputs.
assert_eq "provision: runner_tools value forwarded verbatim via heredoc" "1" \
  "$(grep -cF "printf '%s\\n' \"\$RUNNER_TOOLS\"" "$RUNNER" || true)"
# The Resolve-profile step's RUNNER_TOOLS env is wired to that base-ref output —
# never a PR-head source.
assert_eq "provision: RUNNER_TOOLS env wired to baseprovision output" "1" \
  "$(grep -cF 'RUNNER_TOOLS: ${{ steps.baseprovision.outputs.runner_tools }}' "$RUNNER" || true)"

# (3) The freeform list is appended (the filtered remainder) and that append is
# guarded by `if [ "$PROVISION_ENV" = "true" ]`, so the default profile stays
# byte-for-byte read-only. Locate the append line and confirm the guard precedes
# the deny-list filter block it lives in.
assert_eq "provision: freeform allowed_tools appended to profile" "1" \
  "$(grep -cF 'TOOLS="$TOOLS,$FILTERED"' "$RUNNER" || true)"
assert_eq "provision: freeform append guarded by PROVISION_ENV == true" "1" \
  "$(grep -c 'if \[ "\$PROVISION_ENV" = "true" \]' "$RUNNER" || true)"
# Structural: the append must sit AFTER the PROVISION_ENV guard, not merely
# coexist in the file — else a future dedent could append build tools to the
# default read-only profile while both greps above still pass. Pin line order.
APPEND_LN=$(grep -nF 'TOOLS="$TOOLS,$FILTERED"' "$RUNNER" | head -1 | cut -d: -f1)
GUARD_LN=$(grep -n 'if \[ "\$PROVISION_ENV" = "true" \]' "$RUNNER" | head -1 | cut -d: -f1)
assert_eq "provision: freeform append is inside the PROVISION_ENV guard (guard precedes append)" "yes" \
  "$([ -n "$APPEND_LN" ] && [ -n "$GUARD_LN" ] && [ "$GUARD_LN" -lt "$APPEND_LN" ] && echo yes || echo no)"

# (4) Deny-list floor: the catastrophic tier is stripped before appending. Pin
# the exact-name denies, the command-word denies, and both warnings.
assert_eq "provision: deny-list names present (Edit/Write/MultiEdit/NotebookEdit)" "1" \
  "$(grep -cF "DENY_NAMES='Edit Write MultiEdit NotebookEdit'" "$RUNNER" || true)"
assert_eq "provision: deny-list shells/eval/privilege present" "1" \
  "$(grep -c "DENY_CMDS='bash sh zsh" "$RUNNER" || true)"
assert_eq "provision: stripped deny-listed entries warned" "1" \
  "$(grep -c 'stripped deny-listed entries' "$RUNNER" || true)"
assert_eq "provision: empty-after-strip warns build-aware review has no tools" "1" \
  "$(grep -c 'build-aware review is enabled with NO build tools' "$RUNNER" || true)"

# The setup-project-env step is gated on the base-ref provision flag.
assert_eq "provision: setup-project-env step present" "1" \
  "$(grep -c 'uses: ./.github/actions/setup-project-env' "$RUNNER" || true)"
assert_eq "provision: setup-project-env gated on base provision_env" "1" \
  "$(grep -c "if: steps.baseprovision.outputs.provision_env == 'true'" "$RUNNER" || true)"

# Coupling: the tool-profile guard and the provision step must read the SAME
# gate. Pin that the tools step's PROVISION_ENV env is wired to
# steps.baseprovision.outputs.provision_env — if it were ever pointed at a
# stale/different source, build tools could be granted without (or without
# matching) a provisioned env, and every other assertion would stay green.
assert_eq "provision: PROVISION_ENV env wired to baseprovision output" "1" \
  "$(grep -cF 'PROVISION_ENV: ${{ steps.baseprovision.outputs.provision_env }}' "$RUNNER" || true)"

# Issue #21 inverted this invariant: the runner now DOES consume
# devflow_runner.allowed_tools (gated on provision_env, deny-list-floored). At
# least one read must be present — if a future change drops it, build-aware
# review silently regresses to read-only and this fails.
assert_eq "provision: runner consumes devflow_runner.allowed_tools" "1" \
  "$(grep -cE 'devflow_runner\.allowed_tools' "$RUNNER" | awk '{print ($1>=1)?1:0}')"
# The schema must no longer mark the key deprecated (it is live again).
assert_eq "provision: schema does not mark allowed_tools deprecated" "null" \
  "$(jq -r '.properties.devflow_runner.properties.allowed_tools.deprecated' "$LIB/../.devflow/config.schema.json")"

# Fast-feedback deny-list guard in detect-project-tools.sh: the runner write must
# go through the filtered $runner_tools var (not raw $tools), and a `denylisted`
# filter must be defined — so /devflow:init never writes a deny-listed tool into
# devflow_runner.allowed_tools.
DETECT="$LIB/../scripts/detect-project-tools.sh"
assert_eq "provision: detect defines a denylisted jq filter" "1" \
  "$(grep -c 'def denylisted:' "$DETECT" || true)"
assert_eq "provision: detect filters runner write through denylisted" "1" \
  "$(grep -cF 'select(denylisted | not)' "$DETECT" || true)"
assert_eq "provision: detect runner write uses filtered \$runner_tools" "1" \
  "$(grep -cF '.devflow_runner.allowed_tools    = ((.devflow_runner.allowed_tools    // []) + $runner_tools' "$DETECT" || true)"

# Behavioral: actually RUN the 'tools' step's deny-list filter. The static greps
# above only prove the deny-list STRINGS exist, not that filtering works — and
# this is a security boundary, so logic regressions (a broken command-word split,
# the multi-word bypass Bash(sudo rm:*), a guard that stops gating) must fail the
# suite. We extract the step's run: script and exercise it under several inputs.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  TOOLS_STEP=$(mktemp)
  python3 - "$RUNNER" >"$TOOLS_STEP" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for job in doc["jobs"].values():
    for s in job.get("steps", []):
        if s.get("id") == "tools" and "run" in s:
            sys.stdout.write("#!/usr/bin/env bash\nset -euo pipefail\n" + s["run"])
            raise SystemExit
raise SystemExit("tools step not found")
PY
  # Emit the full resolved TOOLS string for a given provision flag + runner list.
  # Capture the exit code: a crashed step (e.g. a set -e abort mid-filter) must
  # NOT masquerade as "nothing appended" and let a stripping assertion pass — on
  # failure we emit a sentinel so the assertion fails loudly.
  emit_tools() {  # $1=PROVISION_ENV  $2=RUNNER_TOOLS
    local out rc; out=$(mktemp)
    PROFILE=review PROVISION_ENV="$1" RUNNER_TOOLS="$2" GITHUB_OUTPUT="$out" \
      bash "$TOOLS_STEP" >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then printf '__EMIT_FAILED_rc=%s__' "$rc"; rm -f "$out"; return; fi
    awk '/^tools<</{f=1;next} (f && /^EOF_/){f=0} f' "$out"
    rm -f "$out"
  }
  # The read-only base = provisioning off; the freeform append is everything the
  # filter adds on top of it.
  BASE_TOOLS=$(emit_tools false '')
  append_of() { local full; full=$(emit_tools "$1" "$2"); printf '%s' "${full#"$BASE_TOOLS"}"; }
  # Guards a "stripped" case can't pass via a crash: the read-only base must still
  # be fully present (proving the step ran to completion and ONLY dropped denies).
  base_intact() { case "$(emit_tools "$1" "$2")" in "$BASE_TOOLS"*) echo yes ;; *) echo no ;; esac; }

  # The base itself must be the real read-only profile, not an empty/garbled value
  # (otherwise the prefix-strip lens would hide base-profile regressions).
  assert_eq "provision(behavior): base profile is the read-only anchor" "yes" \
    "$(case "$BASE_TOOLS" in Read,Glob,Grep*) echo yes ;; *) echo no ;; esac)"

  # Multi-word raw-shell / privilege entries are stripped (deny by the binary).
  assert_eq "provision(behavior): Bash(sudo rm:*) stripped" "" \
    "$(append_of true 'Bash(sudo rm:*)')"
  assert_eq "provision(behavior): Bash(sh -c:*) stripped" "" \
    "$(append_of true 'Bash(sh -c:*)')"
  # Wrapper / path / env-assignment / bare-or-empty evasions are all stripped.
  assert_eq "provision(behavior): Bash(env bash:*) wrapper stripped" "" \
    "$(append_of true 'Bash(env bash:*)')"
  assert_eq "provision(behavior): Bash(/bin/bash:*) path-form stripped" "" \
    "$(append_of true 'Bash(/bin/bash:*)')"
  assert_eq "provision(behavior): Bash(xargs sh -c:*) wrapper stripped" "" \
    "$(append_of true 'Bash(xargs sh -c:*)')"
  assert_eq "provision(behavior): Bash(FOO=1 bash:*) env-assignment stripped" "" \
    "$(append_of true 'Bash(FOO=1 bash:*)')"
  assert_eq "provision(behavior): bare Bash stripped" "" \
    "$(append_of true 'Bash')"
  assert_eq "provision(behavior): Bash(:*) empty-cmd stripped" "" \
    "$(append_of true 'Bash(:*)')"
  # Newline-smuggled second tool: the producer forwards newlines verbatim, so the
  # consumer must normalize them — the embedded Bash(sudo:*) must be stripped.
  assert_eq "provision(behavior): newline-smuggled Bash(sudo:*) stripped" ",Bash(go:*)" \
    "$(append_of true "$(printf 'Bash(go:*)\nBash(sudo:*)')")"
  # Each stripped case ran to completion (base profile intact), not crashed.
  assert_eq "provision(behavior): base intact after stripping env-wrapper" "yes" \
    "$(base_intact true 'Bash(env bash:*)')"
  assert_eq "provision(behavior): base intact after stripping path-form" "yes" \
    "$(base_intact true 'Bash(/bin/bash:*)')"
  # Bare-word denies + a file-mutation tool are stripped.
  assert_eq "provision(behavior): Write + Bash(bash:*) stripped" "" \
    "$(append_of true 'Write,Bash(bash:*)')"
  # Legitimate build tools survive — including an internal space and a lookalike
  # prefix (shellcheck must NOT be caught by the 'sh' deny).
  assert_eq "provision(behavior): clean build tools survive" ",Bash(go:*),Bash(go build:*),Bash(shellcheck:*)" \
    "$(append_of true 'Bash(go:*),Bash(go build:*),Bash(shellcheck:*)')"
  # Provisioning off → nothing appended even with a non-empty list (read-only).
  assert_eq "provision(behavior): provision_env=false appends nothing" "" \
    "$(append_of false 'Bash(go:*),Bash(cargo:*)')"
  # Provisioning on + empty list → nothing appended (the warning is grepped above).
  assert_eq "provision(behavior): provision_env=true empty list appends nothing" "" \
    "$(append_of true '')"
  # Mixed list: denies dropped, clean kept, order preserved.
  assert_eq "provision(behavior): mixed list keeps only clean entries" ",Bash(go:*),Bash(make:*)" \
    "$(append_of true 'Bash(go:*),Bash(sudo:*),Edit,Bash(make:*)')"
  # Regression guard (must NOT over-strip): a deny word as a SUBCOMMAND or arg of a
  # non-wrapper command, or as a path arg, is legitimate and must survive — only
  # the command-position binary is inspected.
  assert_eq "provision(behavior): Bash(docker exec:*) kept (exec is a docker subcommand)" ",Bash(docker exec:*)" \
    "$(append_of true 'Bash(docker exec:*)')"
  assert_eq "provision(behavior): Bash(make CC=gcc:*) kept (= is a make arg, not a leading assignment)" ",Bash(make CC=gcc:*)" \
    "$(append_of true 'Bash(make CC=gcc:*)')"
  assert_eq "provision(behavior): Bash(go run ./cmd/sh:*) kept (sh is a path arg)" ",Bash(go run ./cmd/sh:*)" \
    "$(append_of true 'Bash(go run ./cmd/sh:*)')"
  # Shell-metacharacter entries are stripped (classic "append a second command").
  assert_eq "provision(behavior): Bash(go;sudo:*) metachar stripped" "" \
    "$(append_of true 'Bash(go;sudo:*)')"
  assert_eq "provision(behavior): Bash(cat x|sh:*) pipe-to-shell stripped" "" \
    "$(append_of true 'Bash(cat x|sh:*)')"
  # Closing-paren-before-colon form is stripped (shell must match the jq mirror).
  assert_eq "provision(behavior): Bash(sh):* stripped" "" \
    "$(append_of true 'Bash(sh):*')"
  # Leading env-assignment with non-identifier name (go.x=1) stripped, matching jq.
  assert_eq "provision(behavior): Bash(go.x=1:*) leading-assignment stripped" "" \
    "$(append_of true 'Bash(go.x=1:*)')"
  rm -f "$TOOLS_STEP"

  # Behavioral test of the detect-project-tools.sh jq deny mirror: extract the
  # `denylisted` def from the script (so this tracks the real filter, not a copy)
  # and assert it agrees with the runner on the same evasion corpus.
  DENYDEF=$(awk '/def denylisted:/{f=1} f{print} f&&/end;/{exit}' "$DETECT")
  jq_deny() { jq -rn --arg e "$1" "$DENYDEF"' ($e | denylisted)'; }
  assert_eq "provision(jq-mirror): Edit denied" "true" "$(jq_deny 'Edit')"
  assert_eq "provision(jq-mirror): Bash(sudo rm:*) denied" "true" "$(jq_deny 'Bash(sudo rm:*)')"
  assert_eq "provision(jq-mirror): Bash(env bash:*) denied" "true" "$(jq_deny 'Bash(env bash:*)')"
  assert_eq "provision(jq-mirror): Bash(/bin/bash:*) denied" "true" "$(jq_deny 'Bash(/bin/bash:*)')"
  assert_eq "provision(jq-mirror): Bash(FOO=1 bash:*) denied" "true" "$(jq_deny 'Bash(FOO=1 bash:*)')"
  assert_eq "provision(jq-mirror): bare Bash denied" "true" "$(jq_deny 'Bash')"
  assert_eq "provision(jq-mirror): Bash(go;sudo:*) metachar denied" "true" "$(jq_deny 'Bash(go;sudo:*)')"
  assert_eq "provision(jq-mirror): Bash(sh):* denied (paren-before-colon)" "true" "$(jq_deny 'Bash(sh):*')"
  assert_eq "provision(jq-mirror): Bash(go:*) allowed" "false" "$(jq_deny 'Bash(go:*)')"
  assert_eq "provision(jq-mirror): Bash(go build:*) allowed" "false" "$(jq_deny 'Bash(go build:*)')"
  assert_eq "provision(jq-mirror): Bash(shellcheck:*) allowed (lookalike)" "false" "$(jq_deny 'Bash(shellcheck:*)')"
  assert_eq "provision(jq-mirror): Bash(docker exec:*) allowed (subcommand)" "false" "$(jq_deny 'Bash(docker exec:*)')"
  assert_eq "provision(jq-mirror): Bash(make CC=gcc:*) allowed (arg assignment)" "false" "$(jq_deny 'Bash(make CC=gcc:*)')"
  # Env-assignment regex aligned with the runner's `[A-Za-z_]*=*` glob: a leading
  # assignment whose name has non-identifier chars (go.x=1) must deny in BOTH.
  assert_eq "provision(jq-mirror): Bash(go.x=1:*) leading-assignment denied" "true" "$(jq_deny 'Bash(go.x=1:*)')"
else
  echo "  SKIP  provision(behavior): python3+pyyaml unavailable; static assertions only"
fi

# Trust boundary on the SETUP channel (the one that carries setup.install): the
# provision step's config_json must come from steps.baseprovision (base ref),
# NOT steps.cfg / steps.extract (the PR-head config). A regression here would
# re-open setup.install injection while every flag-side assertion stayed green.
assert_eq "provision: setup config_json sourced from base (steps.baseprovision)" "1" \
  "$(grep -cF 'config_json: ${{ steps.baseprovision.outputs.config_json }}' "$RUNNER" || true)"

# The malformed/non-object base-config fallback must reset BASE_JSON to '{}' and
# warn (collapse to read-only), not abort the job. Pin both halves of that arm.
assert_eq "provision: malformed base config resets BASE_JSON to {}" "1" \
  "$(grep -c "BASE_JSON='{}'" "$RUNNER" | awk '{print ($1>=1)?1:0}')"
assert_eq "provision: malformed/non-object base config warns + read-only" "1" \
  "$(grep -c 'malformed or non-object .devflow/config.json' "$RUNNER" || true)"

# Trust boundary: the flag and setup block come from the base ref. BASE_REF is
# sourced from the trusted event payload, fetched from origin, and read out of
# FETCH_HEAD — never the checked-out PR head.
assert_eq "provision: base ref from trusted event payload" "1" \
  "$(grep -c 'github.event.pull_request.base.ref || github.event.repository.default_branch' "$RUNNER" || true)"
assert_eq "provision: base config fetched from origin BASE_REF" "1" \
  "$(grep -c 'git fetch --depth=1 origin "\$BASE_REF"' "$RUNNER" || true)"
assert_eq "provision: provision_env read from FETCH_HEAD base config" "1" \
  "$(grep -c 'FETCH_HEAD:.devflow/config.json' "$RUNNER" || true)"

# Security: the flag is read EXACTLY ONCE, and only from the base-ref config
# ($BASE_JSON) — never from the PR-head config ($CONFIG_JSON, the extract step).
# We locate every jq read of `.devflow_runner.provision_env`: there must be one,
# and it must pipe from BASE_JSON (and not CONFIG_JSON). A same-line CONFIG_JSON
# negative alone was too weak — a refactor reading the flag from the head config
# via an intermediate variable would slip past it and silently re-open the
# self-escalation hole.
PROV_READS=$(grep -nE '\.devflow_runner\.provision_env' "$RUNNER" | grep 'jq ' || true)
assert_eq "provision: flag read exactly once (jq)" "1" \
  "$(printf '%s\n' "$PROV_READS" | grep -c '^[0-9]' || true)"
assert_eq "provision: flag read from base config (BASE_JSON), not PR-head CONFIG_JSON" "yes" \
  "$(printf '%s\n' "$PROV_READS" | grep -q 'BASE_JSON' \
     && ! printf '%s\n' "$PROV_READS" | grep -q 'CONFIG_JSON' && echo yes || echo no)"
# The read uses the `== true` clamp, so the emitted GITHUB_OUTPUT token is always
# the literal `true`/`false` that both consumers (the step `if:` and the shell
# guard) compare against — and only a real boolean true enables provisioning.
assert_eq "provision: flag read uses the '== true' clamp" "yes" \
  "$(printf '%s\n' "$PROV_READS" | grep -q 'provision_env == true' && echo yes || echo no)"

# Schema + example: the property is declared (boolean, default false) and the
# example config carries it so editors and adopters see it.
assert_eq "provision: schema declares provision_env boolean" "boolean" \
  "$(jq -r '.properties.devflow_runner.properties.provision_env.type' "$LIB/../.devflow/config.schema.json")"
assert_eq "provision: schema default is false" "false" \
  "$(jq -r '.properties.devflow_runner.properties.provision_env.default' "$LIB/../.devflow/config.schema.json")"
assert_eq "provision: config.example.json sets provision_env false" "false" \
  "$(jq -r '.devflow_runner.provision_env' "$LIB/../.devflow/config.example.json")"

# ────────────────────────────────────────────────────────────────────────────
echo "docs per-step toggles (docs.internal_enabled / docs.external_enabled)"
# ────────────────────────────────────────────────────────────────────────────
# The /devflow:docs pass gates Step 1 (internal) and Step 2 (external) on these
# booleans (default true). Pin the schema declaration, the example, and — most
# importantly — that config-get.sh returns a literal "false" for a false flag
# (not coerced to the default), since the skill's skip decision compares against
# "false". A regression that coerced false→default would silently re-enable a
# disabled step.
SCHEMA="$LIB/../.devflow/config.schema.json"
for key in internal_enabled external_enabled; do
  assert_eq "docs toggle: schema declares $key boolean" "boolean" \
    "$(jq -r ".properties.docs.properties.${key}.type" "$SCHEMA")"
  assert_eq "docs toggle: schema default $key is true" "true" \
    "$(jq -r ".properties.docs.properties.${key}.default" "$SCHEMA")"
done
# config-get.sh must surface a false flag as the literal string "false".
DOCS_CFG="$(mktemp)"; printf '{"docs":{"internal_enabled":false,"external_enabled":true}}' > "$DOCS_CFG"
assert_eq "docs toggle: config-get returns literal false (not the default)" "false" \
  "$(bash "$LIB/../scripts/config-get.sh" .docs.internal_enabled true "$DOCS_CFG")"
assert_eq "docs toggle: config-get returns true when set true" "true" \
  "$(bash "$LIB/../scripts/config-get.sh" .docs.external_enabled false "$DOCS_CFG")"
DOCS_CFG_BARE="$(mktemp)"; printf '{"docs":{}}' > "$DOCS_CFG_BARE"
assert_eq "docs toggle: config-get falls back to default when key absent" "true" \
  "$(bash "$LIB/../scripts/config-get.sh" .docs.internal_enabled true "$DOCS_CFG_BARE")"
rm -f "$DOCS_CFG" "$DOCS_CFG_BARE"
# The docs skill must actually consult both toggles (guards against silent drift
# where the schema declares a flag the skill never reads).
DOCS_SKILL="$LIB/../skills/docs/SKILL.md"
assert_eq "docs toggle: skill reads .docs.internal_enabled" "1" \
  "$(grep -c '\.docs\.internal_enabled' "$DOCS_SKILL" || true)"
assert_eq "docs toggle: skill reads .docs.external_enabled" "1" \
  "$(grep -c '\.docs\.external_enabled' "$DOCS_SKILL" || true)"

# ────────────────────────────────────────────────────────────────────────────
echo "vendor-slice.sh (runtime plugin materialization: committed → self → fetch)"
# ────────────────────────────────────────────────────────────────────────────
VENDOR="$LIB/../.github/actions/vendor-plugin/vendor-slice.sh"
REPO_ROOT="$(cd "$LIB/.." && pwd)"
vexists() { [ -e "$1" ] && echo yes || echo no; }

# committed branch — a pre-populated dest (already has scripts/) is left as-is.
VS_COMMIT="$(mktemp -d)/dest"; mkdir -p "$VS_COMMIT/scripts"; : > "$VS_COMMIT/scripts/sentinel"
( cd "$(mktemp -d)" && DEVFLOW_DEST="$VS_COMMIT" bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: committed branch is a no-op (sentinel survives)" "yes" "$(vexists "$VS_COMMIT/scripts/sentinel")"

# self branch — cwd is the repo root (has scripts/ + skills/ + plugin.json), so
# the in-tree plugin is copied into dest through the shared slice definition.
VS_SELF="$(mktemp -d)/dest"
( cd "$REPO_ROOT" && DEVFLOW_DEST="$VS_SELF" bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: self branch copies scripts from checkout root" "yes" "$(vexists "$VS_SELF/scripts/resolve-implement-trigger.sh")"
assert_eq "vendor: self branch drops the vendored marketplace.json" "no" "$(vexists "$VS_SELF/.claude-plugin/marketplace.json")"
assert_eq "vendor: self branch keeps plugin.json" "yes" "$(vexists "$VS_SELF/.claude-plugin/plugin.json")"
assert_eq "vendor: self branch copies the .devflow templates" "yes" "$(vexists "$VS_SELF/.devflow/config.schema.json")"

# fetch branch — no plugin in cwd; clone a local fixture remote (offline) and
# copy its slice in. Exercises the clone-by-ref + copy path without the network.
VS_REMOTE="$(mktemp -d)"
mkdir -p "$VS_REMOTE"/.claude-plugin "$VS_REMOTE"/agents "$VS_REMOTE"/docs \
        "$VS_REMOTE"/lib "$VS_REMOTE"/scripts "$VS_REMOTE"/skills "$VS_REMOTE"/.devflow
printf '{}' > "$VS_REMOTE/.claude-plugin/plugin.json"
printf '{}' > "$VS_REMOTE/.claude-plugin/marketplace.json"
: > "$VS_REMOTE/scripts/resolve-implement-trigger.sh"
# git won't track empty dirs — give each slice dir a file so the clone carries
# the whole slice (mirrors the real repo, where none of these dirs are empty).
: > "$VS_REMOTE/agents/placeholder.md"
: > "$VS_REMOTE/docs/efficiency-trace.md"
: > "$VS_REMOTE/lib/placeholder.sh"
: > "$VS_REMOTE/skills/placeholder.md"
printf '{}' > "$VS_REMOTE/.devflow/config.example.json"
printf '{}' > "$VS_REMOTE/.devflow/config.schema.json"
printf '{}' > "$VS_REMOTE/.devflow/tool-presets.json"
( cd "$VS_REMOTE" && git init -q -b main && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1
# Capture the BASE (non-tip) commit, then add a second commit carrying a
# tip-only marker inside the slice. `git clone --branch` rejects ANY raw commit
# SHA (it accepts only branch/tag names), so pinning a SHA always forces the
# full-clone + checkout fallback regardless of which commit it is. Using a
# NON-TIP SHA is what makes that checkout VERIFIABLE: the tip-only marker's
# absence in the copied slice proves the fallback checked out the pinned base
# commit rather than the clone's default tip.
VS_BASE_SHA="$(git -C "$VS_REMOTE" rev-parse HEAD)"
: > "$VS_REMOTE/scripts/tip-only-marker.sh"
( cd "$VS_REMOTE" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm 'tip commit' ) >/dev/null 2>&1
VS_FETCH="$(mktemp -d)/dest"
( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$VS_FETCH" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="main" \
    bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: fetch branch clones the pinned ref and copies the slice" "yes" "$(vexists "$VS_FETCH/scripts/resolve-implement-trigger.sh")"
assert_eq "vendor: fetch branch drops the vendored marketplace.json" "no" "$(vexists "$VS_FETCH/.claude-plugin/marketplace.json")"
# docs/ must travel with the slice so skills' relative ../../docs/… links resolve
# offline in the materialized plugin (no web access in the runner sandbox).
assert_eq "vendor: fetch branch copies docs/ (offline skill links resolve)" "yes" "$(vexists "$VS_FETCH/docs/efficiency-trace.md")"

# fetch branch pinned to a NON-TIP commit SHA. `--branch` rejects any raw SHA,
# so this always takes the full-clone + checkout fallback (the path install.sh's
# default SHA pin hits); the non-tip pin additionally lets the marker-absence
# assertion below prove the checkout landed on the pinned commit.
VS_FETCH_SHA="$(mktemp -d)/dest"
( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$VS_FETCH_SHA" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="$VS_BASE_SHA" \
    bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: fetch branch resolves a commit SHA via the clone fallback" "yes" "$(vexists "$VS_FETCH_SHA/scripts/resolve-implement-trigger.sh")"
# The tip-only marker (added in the second commit) must be ABSENT — proves the
# fallback checked out the pinned base commit, not the clone's default tip.
assert_eq "vendor: SHA fallback checks out the pinned non-tip commit (no tip-only marker)" "no" "$(vexists "$VS_FETCH_SHA/scripts/tip-only-marker.sh")"

# fetch branch with no ref — fails loud rather than tracking mutable main.
VS_NOREF_RC=0
( cd "$(mktemp -d)" && env -u DEVFLOW_REF DEVFLOW_DEST="$(mktemp -d)/dest" \
    bash "$VENDOR" >/dev/null 2>&1 ) || VS_NOREF_RC=$?
assert_eq "vendor: fetch branch with no ref fails loud" "yes" \
  "$([ "$VS_NOREF_RC" -ne 0 ] && echo yes || echo no)"

# AC2 drift-guards: install.sh and the composite action both go through the ONE
# shared slice definition, so the copied file set can never diverge.
# Match the executable source line, not the shellcheck-directive comment above it.
assert_eq "vendor: install.sh sources the shared slice script" "1" \
  "$(grep -cE '^[^#]*vendor-slice\.sh' "$REPO_ROOT/install.sh" || true)"
assert_eq "vendor: install.sh calls the shared copy function" "1" \
  "$(grep -c 'devflow_copy_slice "\$SRC"' "$REPO_ROOT/install.sh" || true)"
# Match the run: invocation, not the description prose that also names the script.
assert_eq "vendor: composite action runs the shared slice script" "1" \
  "$(grep -cE 'run:.*vendor-slice\.sh' "$REPO_ROOT/.github/actions/vendor-plugin/action.yml" || true)"
# install.sh must COMMIT the vendor-plugin action even on a thin install — the
# workflows reference it, so a missing copy breaks every cloud run.
assert_eq "vendor: install.sh copies the vendor-plugin composite action" "1" \
  "$(grep -cE 'for a in .*vendor-plugin' "$REPO_ROOT/install.sh" || true)"
# AC8 placement drift-guard: the vendor-plugin composite action reads files at
# ./.github/actions/…, so the repo must be checked out BEFORE it runs in every
# plugin-using job (six across the four workflows). Scan each workflow, reset the
# "checkout seen" flag at each 2-space job/section boundary, and tally each
# vendor-plugin use as ok only if an actions/checkout preceded it in the same job.
VP_PLACEMENT="$(awk '
  FNR==1 { seen=0 }
  /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { seen=0 }
  /uses:[[:space:]]*actions\/checkout/ { seen=1 }
  /uses:[[:space:]]*\.\/\.github\/actions\/vendor-plugin/ { if (seen) ok++; else bad++ }
  END { print (ok+0)"/"(bad+0) }
' "$REPO_ROOT"/.github/workflows/*.yml)"
assert_eq "vendor: vendor-plugin runs after checkout in all six plugin jobs" "6/0" "$VP_PLACEMENT"

# AC3 finalize_check drift-guard: the dismiss call must be preceded by an
# explicit executability check so a vendoring miss (absent script, exit 127)
# is reported distinctly from a present-but-errored run. A workflow-level grep
# guard (the script-absent branch cannot be exercised by the shell harness):
# the `[ ! -x … ]` test and a distinct "absent" warning string must both be
# present in devflow-review.yml.
assert_eq "review: finalize_check guards dismiss with [ -x ] before invoking" "1" \
  "$(grep -c '\[ ! -x "\$DISMISS" \]' "$REVIEW_WF" || true)"
assert_eq "review: finalize_check emits a distinct script-absent warning" "1" \
  "$(grep -c 'dismiss-stale-rejections.sh absent — vendoring did not materialize it' "$REVIEW_WF" || true)"

# devflow_version pin (AC7): declared in the schema and present in the example.
assert_eq "vendor: schema declares devflow_version string" "string" \
  "$(jq -r '.properties.devflow_version.type' "$REPO_ROOT/.devflow/config.schema.json")"
assert_eq "vendor: config.example.json carries devflow_version" "1" \
  "$(jq 'has("devflow_version")' "$REPO_ROOT/.devflow/config.example.json" | grep -c true || true)"
# install.sh stamps it without clobbering other keys (helper present + invoked).
assert_eq "vendor: install.sh defines set_config_version" "1" \
  "$(grep -c 'set_config_version()' "$REPO_ROOT/install.sh" || true)"
assert_eq "vendor: install.sh invokes set_config_version on the config" "1" \
  "$(grep -c 'set_config_version "\.devflow/config\.json"' "$REPO_ROOT/install.sh" || true)"

# committed branch WINS over self: run from the repo root (self-branch markers
# all present) with a pre-populated dest — the committed short-circuit must fire
# so the sentinel survives. Proves precedence, not just an isolated empty-cwd no-op.
VS_PREC="$(mktemp -d)/dest"; mkdir -p "$VS_PREC/scripts"; : > "$VS_PREC/scripts/sentinel"
( cd "$REPO_ROOT" && DEVFLOW_DEST="$VS_PREC" bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: committed branch beats self (precedence)" "yes" "$(vexists "$VS_PREC/scripts/sentinel")"

# self branch copies the FULL slice, not just scripts/ (a dropped cp arg would
# silently ship a plugin missing agents/lib/skills or the tool registry).
assert_eq "vendor: self copies agents/" "yes" "$(vexists "$VS_SELF/agents")"
assert_eq "vendor: self copies docs/" "yes" "$(vexists "$VS_SELF/docs")"
# A known doc lands, so the skills' relative ../../docs/efficiency-trace.md link
# resolves to a real file in the materialized plugin.
assert_eq "vendor: self copies docs/efficiency-trace.md" "yes" "$(vexists "$VS_SELF/docs/efficiency-trace.md")"
assert_eq "vendor: self copies lib/" "yes" "$(vexists "$VS_SELF/lib")"
assert_eq "vendor: self copies skills/" "yes" "$(vexists "$VS_SELF/skills")"
assert_eq "vendor: self copies .devflow/tool-presets.json" "yes" "$(vexists "$VS_SELF/.devflow/tool-presets.json")"

# self-branch NEGATIVE: a consumer repo with its OWN top-level scripts/+skills/
# but a non-devflow plugin.json must NOT be mistaken for the source repo — it
# falls through to fetch. Guards the plugin.json name discriminator.
VS_DECOY="$(mktemp -d)"; mkdir -p "$VS_DECOY/scripts" "$VS_DECOY/skills" "$VS_DECOY/.claude-plugin"
printf '{"name":"not-devflow"}' > "$VS_DECOY/.claude-plugin/plugin.json"
: > "$VS_DECOY/scripts/their-own-tool.sh"
VS_DECOY_DEST="$(mktemp -d)/dest"
( cd "$VS_DECOY" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$VS_DECOY_DEST" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="main" \
    bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: decoy consumer falls through to fetch (not self)" "yes" "$(vexists "$VS_DECOY_DEST/scripts/resolve-implement-trigger.sh")"
assert_eq "vendor: decoy consumer's own scripts/ not taken as the plugin" "no" "$(vexists "$VS_DECOY_DEST/scripts/their-own-tool.sh")"

# fetch with an unreachable ref fails loud (no silent empty/partial dest).
VS_BADREF_RC=0
( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$(mktemp -d)/dest" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="no-such-ref-xyz" \
    bash "$VENDOR" >/dev/null 2>&1 ) || VS_BADREF_RC=$?
assert_eq "vendor: fetch with unreachable ref fails loud" "yes" \
  "$([ "$VS_BADREF_RC" -ne 0 ] && echo yes || echo no)"

# Clone-failure diagnostics (AC1/AC2): a genuine fetch failure must surface its
# real cause in the die message, and a failed checkout after a successful clone
# must be textually distinguishable from a total clone failure. Capture stderr
# (the die stream) rather than discarding it, and assert the distinct phrasing.
# (Exercises the shared clone-chain logic that install.sh mirrors verbatim.)
#
# checkout-fail: a valid remote but an unreachable ref — the fast --branch
# attempt fails quietly, the fallback full-clone succeeds, the checkout fails.
VS_CKOUT_ERR="$( ( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$(mktemp -d)/dest" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="no-such-ref-xyz" \
    bash "$VENDOR" ) 2>&1 >/dev/null )" || true
assert_eq "vendor: unreachable ref surfaces 'clone succeeded but checkout failed'" "yes" \
  "$(printf '%s' "$VS_CKOUT_ERR" | grep -q 'clone succeeded but checkout failed' && echo yes || echo no)"
# total clone failure: an unreachable URL — both clone attempts fail, so the die
# reports 'clone failed' and must NOT be mislabeled as a checkout failure.
VS_CLONE_ERR="$( ( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$(mktemp -d)/dest" DEVFLOW_REPO_URL="$(mktemp -d)/no-such-repo.git" DEVFLOW_REF="main" \
    bash "$VENDOR" ) 2>&1 >/dev/null )" || true
assert_eq "vendor: unreachable URL surfaces 'clone failed'" "yes" \
  "$(printf '%s' "$VS_CLONE_ERR" | grep -q 'clone failed' && echo yes || echo no)"
assert_eq "vendor: total clone failure is not mislabeled as a checkout failure" "no" \
  "$(printf '%s' "$VS_CLONE_ERR" | grep -q 'checkout failed' && echo yes || echo no)"

# devflow_copy_slice no-partial-copy guarantee: an incomplete source must abort
# non-zero AND leave $dest untouched — $dest is only ever created by the final
# atomic mv, so a partial copy never lands where the committed-branch check would
# later mistake it for a valid plugin. Two abort paths back this guarantee, and
# we cover BOTH:
#   (a) a missing slice dir trips `cp -R "$src/scripts"` under set -e (the abort
#       fires at the cp, before the explicit floor check); and
#   (b) the explicit sanity floor (vendor-slice.sh) fires when cp SUCCEEDS but a
#       load-bearing member (plugin.json) didn't land.
# Source the shared definition (DEVFLOW_VENDOR_SOURCE=1 returns without running).
#
# (a) source missing scripts/ — cp aborts under set -e (matches AC: "source
#     missing scripts/ → non-zero exit AND $dest non-existent").
VS_BADSRC="$(mktemp -d)"
mkdir -p "$VS_BADSRC"/.claude-plugin "$VS_BADSRC"/agents "$VS_BADSRC"/docs \
        "$VS_BADSRC"/lib "$VS_BADSRC"/skills "$VS_BADSRC"/.devflow   # NOTE: no scripts/
printf '{}' > "$VS_BADSRC/.claude-plugin/plugin.json"
printf '{}' > "$VS_BADSRC/.devflow/config.example.json"
printf '{}' > "$VS_BADSRC/.devflow/config.schema.json"
printf '{}' > "$VS_BADSRC/.devflow/tool-presets.json"
VS_FLOOR_DEST="$(mktemp -d)/dest"   # parent exists; dest itself must NOT be created
VS_FLOOR_RC=0
# shellcheck disable=SC1090
( DEVFLOW_VENDOR_SOURCE=1 . "$VENDOR" && devflow_copy_slice "$VS_BADSRC" "$VS_FLOOR_DEST" ) >/dev/null 2>&1 || VS_FLOOR_RC=$?
assert_eq "vendor: missing scripts/ aborts the copy (cp-under-set-e guard)" "yes" \
  "$([ "$VS_FLOOR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "vendor: missing scripts/ leaves dest non-existent (no partial copy lands)" "no" \
  "$(vexists "$VS_FLOOR_DEST")"

# (b) source whose dirs all copy cleanly but with NO plugin.json — cp succeeds,
#     so this genuinely reaches and trips the explicit sanity-floor check.
VS_FLOORSRC="$(mktemp -d)"
mkdir -p "$VS_FLOORSRC"/.claude-plugin "$VS_FLOORSRC"/agents "$VS_FLOORSRC"/docs \
        "$VS_FLOORSRC"/lib "$VS_FLOORSRC"/scripts "$VS_FLOORSRC"/skills "$VS_FLOORSRC"/.devflow
# NOTE: no .claude-plugin/plugin.json — the floor's plugin.json check must fire.
printf '{}' > "$VS_FLOORSRC/.devflow/config.example.json"
printf '{}' > "$VS_FLOORSRC/.devflow/config.schema.json"
printf '{}' > "$VS_FLOORSRC/.devflow/tool-presets.json"
VS_FLOORSRC_DEST="$(mktemp -d)/dest"
VS_FLOORSRC_RC=0
# Capture stderr (the die stream) so we can assert the abort came from the FLOOR,
# not an early cp-under-set-e abort. Without this, a future change that added a
# required member to devflow_copy_slice's cp list (without adding it to this
# fixture) would silently degrade case (b) into a duplicate of case (a) and lose
# all coverage of the explicit floor branch while staying green.
# shellcheck disable=SC1090
VS_FLOORSRC_ERR="$( ( DEVFLOW_VENDOR_SOURCE=1 . "$VENDOR" \
    && devflow_copy_slice "$VS_FLOORSRC" "$VS_FLOORSRC_DEST" ) 2>&1 >/dev/null )" || VS_FLOORSRC_RC=$?
assert_eq "vendor: sanity floor aborts when plugin.json didn't land (cp succeeded)" "yes" \
  "$([ "$VS_FLOORSRC_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "vendor: floor abort is the floor's doing, not a cp-under-set-e abort" "yes" \
  "$(printf '%s' "$VS_FLOORSRC_ERR" | grep -q 'incomplete plugin slice copied' && echo yes || echo no)"
assert_eq "vendor: sanity floor leaves dest non-existent (no partial copy lands)" "no" \
  "$(vexists "$VS_FLOORSRC_DEST")"
rm -rf "$VS_BADSRC" "$(dirname "$VS_FLOOR_DEST")" "$VS_FLOORSRC" "$(dirname "$VS_FLOORSRC_DEST")"

# set_config_version (install.sh) BEHAVIORAL: pins devflow_version without
# clobbering other keys, and a present-but-failing tool (malformed config)
# degrades to a warning + return 0 rather than aborting the install.
if command -v jq >/dev/null 2>&1; then
  SCV_INSTALL="$LIB/../install.sh"
  SCV_CFG="$(mktemp)"; printf '{"base_branch":"main","devflow":{"effort":"high"}}' > "$SCV_CFG"
  # shellcheck disable=SC1090
  ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_CFG" "abc123" ) >/dev/null 2>&1
  assert_eq "scv: pins devflow_version" "abc123" "$(jq -r '.devflow_version' "$SCV_CFG")"
  assert_eq "scv: preserves sibling top-level key" "main" "$(jq -r '.base_branch' "$SCV_CFG")"
  assert_eq "scv: preserves nested key" "high" "$(jq -r '.devflow.effort' "$SCV_CFG")"
  SCV_BAD="$(mktemp)"; printf '{ not valid json' > "$SCV_BAD"
  SCV_RC=0
  # shellcheck disable=SC1090
  ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_BAD" "abc123" ) >/dev/null 2>&1 || SCV_RC=$?
  assert_eq "scv: malformed config → returns 0 (degrades, never aborts)" "0" "$SCV_RC"
  rm -f "$SCV_CFG" "$SCV_BAD"
fi

# set_config_version cross-language backends: jq is selected first on CI, so the
# node and python3 arms never run under the block above. Force the lower backends
# by shadowing the higher tools off PATH — a curated bin dir holding only the
# tools that backend needs (jq, and for python3 also node, deliberately omitted).
# Scoped to a subshell so the PATH mutation can't leak into later assertions.
SCV_INSTALL="$LIB/../install.sh"
scv_mkbin() {  # $1=dest bin dir; rest=command names to symlink from the real PATH
  # PATH is fully REPLACED with this dir in the caller, so list every external
  # command the backend invokes. Fail loud on an unresolvable tool — a silently
  # incomplete bin dir would make set_config_version degrade to its warning path
  # and surface as an opaque assertion mismatch rather than a clear setup error.
  local d="$1" c p; shift; mkdir -p "$d"
  for c in "$@"; do
    p="$(command -v "$c")" || { echo "scv_mkbin: required command not found: $c" >&2; return 1; }
    ln -sf "$p" "$d/$c"
  done
}
# node backend — jq absent, node present.
if command -v node >/dev/null 2>&1; then
  SCV_NODE_BIN="$(mktemp -d)/bin"
  scv_mkbin "$SCV_NODE_BIN" node mktemp mv rm   # jq deliberately omitted
  SCV_NODE_CFG="$(mktemp)"; printf '{"base_branch":"main","devflow":{"effort":"high"}}' > "$SCV_NODE_CFG"
  # shellcheck disable=SC1090
  ( PATH="$SCV_NODE_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_NODE_CFG" "node-sha" ) >/dev/null 2>&1
  assert_eq "scv(node): pins devflow_version" "node-sha" "$(jq -r '.devflow_version' "$SCV_NODE_CFG")"
  assert_eq "scv(node): preserves sibling top-level key" "main" "$(jq -r '.base_branch' "$SCV_NODE_CFG")"
  assert_eq "scv(node): preserves nested key" "high" "$(jq -r '.devflow.effort' "$SCV_NODE_CFG")"
  rm -f "$SCV_NODE_CFG"
fi
# python3 backend — jq AND node absent, python3 present.
if command -v python3 >/dev/null 2>&1; then
  SCV_PY_BIN="$(mktemp -d)/bin"
  scv_mkbin "$SCV_PY_BIN" python3 mktemp mv rm   # jq AND node deliberately omitted
  SCV_PY_CFG="$(mktemp)"; printf '{"base_branch":"main","devflow":{"effort":"high"}}' > "$SCV_PY_CFG"
  # shellcheck disable=SC1090
  ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_CFG" "py-sha" ) >/dev/null 2>&1
  assert_eq "scv(python3): pins devflow_version" "py-sha" "$(jq -r '.devflow_version' "$SCV_PY_CFG")"
  assert_eq "scv(python3): preserves sibling top-level key" "main" "$(jq -r '.base_branch' "$SCV_PY_CFG")"
  assert_eq "scv(python3): preserves nested key" "high" "$(jq -r '.devflow.effort' "$SCV_PY_CFG")"
  rm -f "$SCV_PY_CFG"
fi

rm -rf "$VS_COMMIT" "$VS_SELF" "$VS_REMOTE" "$VS_FETCH" "$VS_FETCH_SHA" \
       "$VS_PREC" "$VS_DECOY" "$VS_DECOY_DEST"

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
