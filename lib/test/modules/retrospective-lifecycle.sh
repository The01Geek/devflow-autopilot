# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable retrospective-lifecycle contract module (issue #788).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh before this module. Uses assert_eq alone; references
# no monolith helper. Every path derives from LIB via the $LIB-relative REPO_ROOT.
# The inventory in retrospective-lifecycle.inventory.md maps each contract group to
# its former lib/test/run.sh location. Modules may not self-skip.
#
# Owns the lifecycle surface introduced by #788: lib/pattern-state.sh (migrate +
# reconcile), the v2 status arms of lib/compute-patterns.jq, and the lifecycle-record
# write of lib/meta-issue.sh. It covers the NEW behavior; the pre-existing
# compute-patterns/meta-issue/actionable-patterns fail-closed assertions stay inline
# in lib/test/run.sh (a deliberately partial extraction, mirroring
# experiment-records.sh's recorded decision), so the coverage-map owner for those
# files is `retrospective-lifecycle` while some of their assertions still live in
# run.sh.
REPO_ROOT="$LIB/.."

RL_TMP="$(mktemp -d)"
trap 'rm -rf "$RL_TMP"' RETURN

PS="$REPO_ROOT/lib/pattern-state.sh"
MI="$REPO_ROOT/lib/meta-issue.sh"
CP="$REPO_ROOT/lib/compute-patterns.jq"

# ────────────────────────────────────────────────────────────────────────────
echo "#788 compute-patterns.jq v2 status arms"
# ────────────────────────────────────────────────────────────────────────────
rl_cp() { # entries overrides
  printf '%s\n' "$1" | jq -s --slurpfile overrides <(printf '%s' "$2") -f "$CP"
}

# Fix-timestamp precedence (the lenient-verdict shape): a `filed` record with a
# legacy audit fix predating the newest occurrence reports `filed`, NOT `regressed`.
RL_R=$(rl_cp \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-07-20T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-06-24T00:00:00Z","fixes_patterns":["lenient-verdict"]}' \
  '{"schema_version":2,"patterns":{"lenient-verdict":{"state":"filed","fixed_at":null,"provenance_at":"2026-06-29T00:00:00Z","meta_issues":[{"number":185,"url":"u","state":"filed"}]}},"dismissed":{}}')
assert_eq "#788 precedence: filed record + older audit fix + newer occ → filed" \
  "filed" "$(echo "$RL_R" | jq -r '.["lenient-verdict"].status')"

# A declined record whose newest occurrence post-dates its fixed_at → regressed.
RL_R=$(rl_cp \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-07-20T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' \
  '{"schema_version":2,"patterns":{"tooling-gap":{"state":"declined","fixed_at":"2026-06-28T00:00:00Z","provenance_at":"p","meta_issues":[{"number":113,"url":"u","state":"declined"}]}},"dismissed":{}}')
assert_eq "#788 declined + newer occ → regressed" \
  "regressed" "$(echo "$RL_R" | jq -r '.["tooling-gap"].status')"

# A fixed record whose newest occurrence predates its fixed_at → fixed.
RL_R=$(rl_cp \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-07-23T17:32:23Z","verdict":"imperfect","categories":["fabricated-claim"]}' \
  '{"schema_version":2,"patterns":{"fabricated-claim":{"state":"fixed","fixed_at":"2026-07-24T10:11:25Z","provenance_at":"p","meta_issues":[{"number":761,"url":"u","state":"fixed"}]}},"dismissed":{}}')
assert_eq "#788 fixed record + older occ → fixed" \
  "fixed" "$(echo "$RL_R" | jq -r '.["fabricated-claim"].status')"

# A filed record with no newer occurrence → filed.
RL_R=$(rl_cp \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' \
  '{"schema_version":2,"patterns":{"doc-accuracy":{"state":"filed","fixed_at":null,"provenance_at":"p","meta_issues":[{"number":183,"url":"u","state":"filed"}]}},"dismissed":{}}')
assert_eq "#788 filed record + no newer occ → filed" \
  "filed" "$(echo "$RL_R" | jq -r '.["doc-accuracy"].status')"

# The human dismissed{} map is the absolute suppressor: dismissed beats everything.
RL_R=$(rl_cp \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-07-20T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' \
  '{"schema_version":2,"patterns":{"tooling-gap":{"state":"declined","fixed_at":"2026-06-28T00:00:00Z","provenance_at":"p","meta_issues":[{"number":113,"url":"u","state":"declined"}]}},"dismissed":{"tooling-gap":{"dismissed_by":"maintainer"}}}')
assert_eq "#788 human dismissed beats a regressing record → dismissed" \
  "dismissed" "$(echo "$RL_R" | jq -r '.["tooling-gap"].status')"

# A slug with NO record falls through to the legacy fixed/open arms.
RL_R=$(rl_cp \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["other"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "#788 no record + no fix → open" \
  "open" "$(echo "$RL_R" | jq -r '.["other"].status')"

# One canonicalization: a non-canonical stored record key does not surface a
# zero-occurrence phantom (the key is slugified before membership).
RL_R=$(rl_cp \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' \
  '{"schema_version":2,"patterns":{"Doc Accuracy":{"state":"filed","fixed_at":null,"provenance_at":"p","meta_issues":[{"number":183,"url":"u","state":"filed"}]}},"dismissed":{}}')
assert_eq "#788 non-canonical record key canonicalizes onto doc-accuracy (count 1, not a phantom)" \
  "1" "$(echo "$RL_R" | jq '[.[] | .occurrence_count] | add')"

# ────────────────────────────────────────────────────────────────────────────
echo "#788 pattern-state.sh migrate + reconcile"
# ────────────────────────────────────────────────────────────────────────────
# gh stub: prefetch covers #113 (NOT_PLANNED) and #761 (COMPLETED); #114 resolves
# through the by-number fallback (COMPLETED); an OPEN issue #900 is available too.
cat > "$RL_TMP/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "gh version 2.0.0 (stub)"; exit 0; fi
case "$*" in
  *"issue list"*)
    echo '[{"number":113,"state":"CLOSED","stateReason":"NOT_PLANNED","closedAt":"2026-06-28T00:00:00Z"},{"number":761,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-07-24T10:11:25Z"},{"number":900,"state":"OPEN","stateReason":null,"closedAt":null}]' ;;
  *"issue view 114"*) echo '{"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-06-03T00:00:00Z"}' ;;
  *"issue view 900"*) echo '{"state":"OPEN","stateReason":null,"closedAt":null}' ;;
  *"issue view"*)     echo '{"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-06-30T00:00:00Z"}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$RL_TMP/gh"

# Mixed v1 fixture: three loop-written keys + one hand-written key.
cat > "$RL_TMP/ov1.json" <<'JSON'
{"schema_version":1,"dismissed":{
  "tooling-gap":{"dismissed_at":"2026-06-03T21:39:06Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/o/r/issues/113"},
  "incomplete-edit":{"dismissed_at":"2026-06-03T21:39:06Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/o/r/issues/114"},
  "fabricated-claim":{"dismissed_at":"2026-07-24T02:25:21Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/o/r/issues/761"},
  "handwritten-key":{"dismissed_at":"2026-01-01T00:00:00Z","dismissed_by":"maintainer","reason":"stop raising this"}
}}
JSON
DEVFLOW_GH="$RL_TMP/gh" bash "$PS" --overrides "$RL_TMP/ov1.json" >/dev/null 2>&1

assert_eq "#788 migrate: file is schema_version 2" "2" "$(jq -r '.schema_version' "$RL_TMP/ov1.json")"
assert_eq "#788 migrate: hand-written key survives in dismissed{}" "true" \
  "$(jq -e '.dismissed | has("handwritten-key")' "$RL_TMP/ov1.json" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "#788 migrate: dismissed{} holds no loop-written key" "false" \
  "$(jq -e '.dismissed | has("tooling-gap")' "$RL_TMP/ov1.json" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "#788 reconcile: tooling-gap (NOT_PLANNED) → declined" "declined" \
  "$(jq -r '.patterns["tooling-gap"].state' "$RL_TMP/ov1.json")"
assert_eq "#788 reconcile: incomplete-edit (COMPLETED via by-number fallback) → fixed" "fixed" \
  "$(jq -r '.patterns["incomplete-edit"].state' "$RL_TMP/ov1.json")"
assert_eq "#788 reconcile: fabricated-claim (COMPLETED) → fixed" "fixed" \
  "$(jq -r '.patterns["fabricated-claim"].state' "$RL_TMP/ov1.json")"
assert_eq "#788 reconcile stamps fixed_at from closedAt (tooling-gap #113)" "2026-06-28T00:00:00Z" \
  "$(jq -r '.patterns["tooling-gap"].fixed_at' "$RL_TMP/ov1.json")"

# Idempotency: a second run over the reconciled v2 file changes no byte.
cp "$RL_TMP/ov1.json" "$RL_TMP/ov1-before.json"
DEVFLOW_GH="$RL_TMP/gh" bash "$PS" --overrides "$RL_TMP/ov1.json" >/dev/null 2>&1
assert_eq "#788 reconcile is byte-identical on a second run" "yes" \
  "$(cmp -s "$RL_TMP/ov1-before.json" "$RL_TMP/ov1.json" && echo yes || echo no)"

# migrate-then-reconcile-then-derive: statuses reflect the derived view.
RL_DERIVED=$(printf '%s\n' \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-07-20T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' \
  '{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-07-23T17:32:23Z","verdict":"imperfect","categories":["fabricated-claim"]}' \
  | jq -s --slurpfile overrides "$RL_TMP/ov1.json" -f "$CP")
assert_eq "#788 derived: tooling-gap (declined + newer occ) → regressed" "regressed" \
  "$(echo "$RL_DERIVED" | jq -r '.["tooling-gap"].status')"
assert_eq "#788 derived: fabricated-claim (fixed, older occ) → fixed" "fixed" \
  "$(echo "$RL_DERIVED" | jq -r '.["fabricated-claim"].status')"

# Two-entry record: one COMPLETED + one open → both refresh, derives filed, count 1.
cat > "$RL_TMP/ov-two.json" <<'JSON'
{"schema_version":2,"patterns":{"multi":{"state":"filed","fixed_at":null,"provenance_at":"p","meta_issues":[{"number":761,"url":"https://github.com/o/r/issues/761","state":"filed"},{"number":900,"url":"https://github.com/o/r/issues/900","state":"filed"}]}},"dismissed":{}}
JSON
DEVFLOW_GH="$RL_TMP/gh" bash "$PS" --overrides "$RL_TMP/ov-two.json" >/dev/null 2>&1
assert_eq "#788 two-entry record with an open issue derives filed" "filed" \
  "$(jq -r '.patterns["multi"].state' "$RL_TMP/ov-two.json")"
assert_eq "#788 two-entry record keeps both entries (per-category count basis)" "2" \
  "$(jq -r '.patterns["multi"].meta_issues | length' "$RL_TMP/ov-two.json")"
assert_eq "#788 two-entry: filed-entry count within record reads 1" "1" \
  "$(jq -r '[.patterns["multi"].meta_issues[] | select(.state=="filed")] | length' "$RL_TMP/ov-two.json")"

# A record with no issue URL makes no transition and warns.
cat > "$RL_TMP/ov-nourl.json" <<'JSON'
{"schema_version":2,"patterns":{"nourl":{"state":"filed","fixed_at":null,"provenance_at":"p","meta_issues":[]}},"dismissed":{}}
JSON
RL_NOURL_ERR=$(DEVFLOW_GH="$RL_TMP/gh" bash "$PS" --overrides "$RL_TMP/ov-nourl.json" 2>&1 >/dev/null)
assert_eq "#788 record with no issue URL warns naming the slug" "true" \
  "$(case "$RL_NOURL_ERR" in *"::warning::"*"nourl"*) echo true ;; *) echo false ;; esac)"

# Wholesale prefetch failure (non-zero gh exit) → ::error:: and non-zero exit, no write.
cat > "$RL_TMP/gh-fail" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "gh version 2.0.0 (stub)"; exit 0; fi
case "$*" in *"issue list"*) exit 1 ;; *) echo '[]' ;; esac
STUB
chmod +x "$RL_TMP/gh-fail"
cp "$RL_TMP/ov-two.json" "$RL_TMP/ov-pf.json"
cp "$RL_TMP/ov-pf.json" "$RL_TMP/ov-pf-before.json"
RL_PF_RC=0
DEVFLOW_GH="$RL_TMP/gh-fail" bash "$PS" --overrides "$RL_TMP/ov-pf.json" >/dev/null 2>&1 || RL_PF_RC=$?
assert_eq "#788 wholesale prefetch failure → non-zero exit" "true" \
  "$([ "$RL_PF_RC" -ne 0 ] && echo true || echo false)"
assert_eq "#788 wholesale prefetch failure leaves the file byte-unchanged" "yes" \
  "$(cmp -s "$RL_TMP/ov-pf-before.json" "$RL_TMP/ov-pf.json" && echo yes || echo no)"

# Absent overrides → v2 stub written.
DEVFLOW_GH="$RL_TMP/gh" bash "$PS" --overrides "$RL_TMP/ov-absent.json" >/dev/null 2>&1
assert_eq "#788 absent overrides → v2 stub (schema 2, empty maps)" "2 0 0" \
  "$(jq -r '"\(.schema_version) \(.patterns|length) \(.dismissed|length)"' "$RL_TMP/ov-absent.json")"

# ────────────────────────────────────────────────────────────────────────────
echo "#788 meta-issue.sh lifecycle-record write"
# ────────────────────────────────────────────────────────────────────────────
# gh stub: de-dup hits the same open issue #500 every time.
cat > "$RL_TMP/gh-mi" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "gh version 2.0.0 (stub)"; exit 0; fi
case "$*" in
  *"issue list"*) echo '[{"number":500,"url":"https://github.com/o/r/issues/500","title":"[devflow-retrospective] meta: lenient-verdict — x"}]' ;;
  *"issue comment"*) echo 'commented' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$RL_TMP/gh-mi"
printf '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$RL_TMP/ov-mi.json"
printf 'body\n' > "$RL_TMP/body.md"
for _rl_i in 1 2; do
  DEVFLOW_GH="$RL_TMP/gh-mi" bash "$MI" --tag lenient-verdict --slug lenient-verdict \
    --title T --body-file "$RL_TMP/body.md" --overrides "$RL_TMP/ov-mi.json" >/dev/null 2>&1
done
assert_eq "#788 meta-issue: two filings on the same issue keep exactly one entry" "1" \
  "$(jq -r '.patterns["lenient-verdict"].meta_issues | length' "$RL_TMP/ov-mi.json")"
assert_eq "#788 meta-issue: entry keyed by issue number" "500" \
  "$(jq -r '.patterns["lenient-verdict"].meta_issues[0].number' "$RL_TMP/ov-mi.json")"
assert_eq "#788 meta-issue: record state is filed" "filed" \
  "$(jq -r '.patterns["lenient-verdict"].state' "$RL_TMP/ov-mi.json")"
assert_eq "#788 meta-issue writes NO .dismissed entry" "0" \
  "$(jq -r '.dismissed | length' "$RL_TMP/ov-mi.json")"

# --slug grammar validation.
RL_SLUG_RC=0
DEVFLOW_GH="$RL_TMP/gh-mi" bash "$MI" --tag ok --slug "bad slug" --title T \
  --body-file "$RL_TMP/body.md" --overrides "$RL_TMP/ov-mi.json" >/dev/null 2>&1 || RL_SLUG_RC=$?
assert_eq "#788 meta-issue rejects a non-slug --slug (non-zero exit)" "true" \
  "$([ "$RL_SLUG_RC" -ne 0 ] && echo true || echo false)"

# --dry-run writes no lifecycle record.
printf '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$RL_TMP/ov-dry.json"
DEVFLOW_GH="$RL_TMP/gh-mi" bash "$MI" --dry-run --tag lenient-verdict --slug lenient-verdict \
  --title T --body-file "$RL_TMP/body.md" --overrides "$RL_TMP/ov-dry.json" >/dev/null 2>&1
assert_eq "#788 meta-issue --dry-run writes no lifecycle record" "0" \
  "$(jq -r '.patterns | length' "$RL_TMP/ov-dry.json")"
