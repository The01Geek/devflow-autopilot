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

rm -rf "$DT1" "$DT2" "$DT3" "$DT4" "$DT5" "$DT6" "$DT7" "$DT8" "$DT9"

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
