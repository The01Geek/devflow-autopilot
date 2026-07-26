# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable retrospective issue-closure lifecycle module (issue #788).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh before this module. References no monolith helper.
REPO_ROOT="$LIB/.."

# ────────────────────────────────────────────────────────────────────────────
echo "#788 retrospective issue-closure lifecycle"
# ────────────────────────────────────────────────────────────────────────────
RL_PS="$REPO_ROOT/lib/pattern-state.sh"
RL_MI="$REPO_ROOT/lib/meta-issue.sh"
RL_AP="$REPO_ROOT/lib/actionable-patterns.sh"
RL_CP="$REPO_ROOT/lib/compute-patterns.jq"
RL_TMP="$(mktemp -d)"
trap 'rm -rf "$RL_TMP"' RETURN

# cp_run <entries-jsonl> <overrides-json> -> the compute-patterns view on stdout
rl_cp() {
  printf '%s\n' "$1" \
  | jq -s --slurpfile overrides <(printf '%s' "$2") -f "$RL_CP"
}

# ── Migration ────────────────────────────────────────────────────────────────
# A mixed v1 fixture: one loop-written entry (dismissed_by retrospective-weekly)
# and one hand-written entry (a different dismissed_by, no meta_issue).
printf '%s' '{"schema_version":1,"dismissed":{"tooling-gap":{"dismissed_at":"2026-06-03T00:00:00Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/o/r/issues/113"},"my-hand-key":{"dismissed_at":"2026-01-01T00:00:00Z","dismissed_by":"a-human"}}}' > "$RL_TMP/mig.json"
bash "$RL_PS" migrate "$RL_TMP/mig.json" >/dev/null 2>&1
assert_eq "#788 migrate: schema_version becomes 2" "2" "$(jq -r '.schema_version' "$RL_TMP/mig.json")"
assert_eq "#788 migrate: loop-written key becomes a lifecycle record (state filed)" "filed" "$(jq -r '.patterns["tooling-gap"].state' "$RL_TMP/mig.json")"
assert_eq "#788 migrate: lifecycle record carries the v1 meta_issue url" "https://github.com/o/r/issues/113" "$(jq -r '.patterns["tooling-gap"].meta_issues[0].url' "$RL_TMP/mig.json")"
assert_eq "#788 migrate: lifecycle record carries v1 dismissed_at as provenance" "2026-06-03T00:00:00Z" "$(jq -r '.patterns["tooling-gap"].provenance' "$RL_TMP/mig.json")"
assert_eq "#788 migrate: hand-written key survives verbatim in dismissed{}" "a-human" "$(jq -r '.dismissed["my-hand-key"].dismissed_by' "$RL_TMP/mig.json")"
assert_eq "#788 migrate: loop-written key is NOT left in dismissed{}" "false" "$(jq -e '.dismissed | has("tooling-gap")' "$RL_TMP/mig.json" >/dev/null 2>&1 && echo true || echo false)"
# Idempotency: a second migrate over the v2 file changes no byte.
cp "$RL_TMP/mig.json" "$RL_TMP/mig-before.json"
bash "$RL_PS" migrate "$RL_TMP/mig.json" >/dev/null 2>&1
assert_eq "#788 migrate is idempotent (byte-identical second run)" "true" "$(diff -q "$RL_TMP/mig-before.json" "$RL_TMP/mig.json" >/dev/null 2>&1 && echo true || echo false)"

# The migrated hand-written key still reports dismissed through compute-patterns.
assert_eq "#788 migrate: hand-written key still reports dismissed" "dismissed" \
  "$(rl_cp '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["my-hand-key"]}' "$(cat "$RL_TMP/mig.json")" | jq -r '.["my-hand-key"].status')"

# ── Reconcile transitions (stubbed gh) ───────────────────────────────────────
# One gh stub: issue view returns a state keyed by number; list returns [].
cat > "$RL_TMP/gh-view.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then echo '[]'; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  case "$3" in
    501) echo '{"number":501,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-06-01T00:00:00Z"}' ;;
    502) echo '{"number":502,"state":"CLOSED","stateReason":"NOT_PLANNED","closedAt":"2026-06-02T00:00:00Z"}' ;;
    503) echo '{"number":503,"state":"CLOSED","stateReason":"DUPLICATE","closedAt":"2026-06-03T00:00:00Z"}' ;;
    504) echo '{"number":504,"state":"OPEN","stateReason":null,"closedAt":null}' ;;
    505) echo '{"number":505,"state":"CLOSED","stateReason":"WEIRD","closedAt":"2026-06-05T00:00:00Z"}' ;;
    *) echo '{"number":'"$3"',"state":"OPEN","stateReason":null,"closedAt":null}' ;;
  esac
  exit 0
fi
exit 1
STUB
chmod +x "$RL_TMP/gh-view.sh"

rl_record() { # slug number
  printf '{"schema_version":2,"patterns":{"%s":{"state":"filed","fixed_at":null,"provenance":"2026-01-01T00:00:00Z","meta_issues":[{"number":%s,"url":"https://o/r/issues/%s","state":"filed","closedAt":null}]}},"dismissed":{}}' "$1" "$2" "$2"
}
printf '%s' "$(rl_record completed-slug 501)" > "$RL_TMP/t1.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/t1.json" >/dev/null 2>&1
assert_eq "#788 reconcile COMPLETED → record fixed" "fixed" "$(jq -r '.patterns["completed-slug"].state' "$RL_TMP/t1.json")"
assert_eq "#788 reconcile COMPLETED → fixed_at = closedAt" "2026-06-01T00:00:00Z" "$(jq -r '.patterns["completed-slug"].fixed_at' "$RL_TMP/t1.json")"

printf '%s' "$(rl_record declined-slug 502)" > "$RL_TMP/t2.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/t2.json" >/dev/null 2>&1
assert_eq "#788 reconcile NOT_PLANNED → record declined" "declined" "$(jq -r '.patterns["declined-slug"].state' "$RL_TMP/t2.json")"
assert_eq "#788 reconcile NOT_PLANNED → fixed_at stamped" "2026-06-02T00:00:00Z" "$(jq -r '.patterns["declined-slug"].fixed_at' "$RL_TMP/t2.json")"

printf '%s' "$(rl_record dup-slug 503)" > "$RL_TMP/t3.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/t3.json" >/dev/null 2>&1
assert_eq "#788 reconcile DUPLICATE → record declined" "declined" "$(jq -r '.patterns["dup-slug"].state' "$RL_TMP/t3.json")"

printf '%s' "$(rl_record open-slug 504)" > "$RL_TMP/t4.json"
# pre-set a fixed_at to prove OPEN clears it
jq '.patterns["open-slug"].fixed_at = "2025-01-01T00:00:00Z"' "$RL_TMP/t4.json" > "$RL_TMP/t4b.json" && mv "$RL_TMP/t4b.json" "$RL_TMP/t4.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/t4.json" >/dev/null 2>&1
assert_eq "#788 reconcile OPEN → record filed" "filed" "$(jq -r '.patterns["open-slug"].state' "$RL_TMP/t4.json")"
assert_eq "#788 reconcile OPEN → fixed_at cleared" "null" "$(jq -r '.patterns["open-slug"].fixed_at' "$RL_TMP/t4.json")"

# Unrecognized stateReason → no transition + ::warning:: naming the slug.
printf '%s' "$(rl_record weird-slug 505)" > "$RL_TMP/t5.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/t5.json" 2>"$RL_TMP/t5.err" >/dev/null
assert_eq "#788 reconcile unrecognized stateReason → no transition (stays filed)" "filed" "$(jq -r '.patterns["weird-slug"].state' "$RL_TMP/t5.json")"
assert_eq "#788 reconcile unrecognized stateReason → ::warning:: names the slug" "true" \
  "$(grep -q 'weird-slug' "$RL_TMP/t5.err" && grep -q '::warning::' "$RL_TMP/t5.err" && echo true || echo false)"

# Record with no issue URL → no transition + ::warning::.
printf '%s' '{"schema_version":2,"patterns":{"nourl":{"state":"filed","fixed_at":null,"provenance":"2026-01-01T00:00:00Z","meta_issues":[]}},"dismissed":{}}' > "$RL_TMP/t6.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/t6.json" 2>"$RL_TMP/t6.err" >/dev/null
assert_eq "#788 reconcile no-url record → ::warning:: names the slug" "true" \
  "$(grep -q 'nourl' "$RL_TMP/t6.err" && grep -q '::warning::' "$RL_TMP/t6.err" && echo true || echo false)"

# Two-entry record (one COMPLETED, one OPEN) → derives to filed, per-cat count 1.
printf '%s' '{"schema_version":2,"patterns":{"multi":{"state":"filed","fixed_at":null,"provenance":"2026-01-01T00:00:00Z","meta_issues":[{"number":501,"url":"https://o/r/issues/501","state":"filed","closedAt":null},{"number":504,"url":"https://o/r/issues/504","state":"filed","closedAt":null}]}},"dismissed":{}}' > "$RL_TMP/t7.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/t7.json" >/dev/null 2>&1
assert_eq "#788 reconcile two-entry (completed+open) → record filed" "filed" "$(jq -r '.patterns["multi"].state' "$RL_TMP/t7.json")"
assert_eq "#788 reconcile two-entry → completed entry refreshed to fixed" "fixed" "$(jq -r '.patterns["multi"].meta_issues[] | select(.number==501) | .state' "$RL_TMP/t7.json")"
assert_eq "#788 reconcile two-entry → per-category filed count reads 1" "1" "$(jq -r '[.patterns["multi"].meta_issues[] | select(.state=="filed")] | length' "$RL_TMP/t7.json")"

# Wholesale prefetch failure (gh list non-zero) → ::error:: + non-zero, no mutation.
cat > "$RL_TMP/gh-listfail.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then echo "boom" >&2; exit 1; fi
exit 1
STUB
chmod +x "$RL_TMP/gh-listfail.sh"
printf '%s' "$(rl_record x 501)" > "$RL_TMP/t8.json"
cp "$RL_TMP/t8.json" "$RL_TMP/t8-before.json"
DEVFLOW_GH="$RL_TMP/gh-listfail.sh" bash "$RL_PS" reconcile "$RL_TMP/t8.json" 2>"$RL_TMP/t8.err" >/dev/null; RL_T8_RC=$?
assert_eq "#788 reconcile wholesale prefetch failure → non-zero exit" "true" "$([ "$RL_T8_RC" -ne 0 ] && echo true || echo false)"
assert_eq "#788 reconcile wholesale failure → ::error:: breadcrumb" "true" "$(grep -q '::error::' "$RL_TMP/t8.err" && echo true || echo false)"
assert_eq "#788 reconcile wholesale failure → file byte-unchanged" "true" "$(diff -q "$RL_TMP/t8-before.json" "$RL_TMP/t8.json" >/dev/null 2>&1 && echo true || echo false)"

# ── compute-patterns.jq status arms ──────────────────────────────────────────
# Arm order: a lifecycle record at fixed + a later occurrence → regressed (against
# today's pre-#788 arm order this would report the record state; the fixture
# supplies its own RED/GREEN discrimination — no mutation helper).
REGR_OV='{"schema_version":2,"patterns":{"lenient-verdict":{"state":"fixed","fixed_at":"2026-04-01T00:00:00Z","provenance":"x","meta_issues":[{"number":9,"url":"https://o/r/issues/9","state":"fixed","closedAt":"2026-04-01T00:00:00Z"}]}},"dismissed":{}}'
assert_eq "#788 arm order: fixed record + later occ → regressed" "regressed" \
  "$(rl_cp '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}' "$REGR_OV" | jq -r '.["lenient-verdict"].status')"
# Human escape valve still beats the reorder.
DIS_OV='{"schema_version":2,"patterns":{"lenient-verdict":{"state":"fixed","fixed_at":"2026-04-01T00:00:00Z","provenance":"x","meta_issues":[]}},"dismissed":{"lenient-verdict":{"dismissed_by":"a-human"}}}'
assert_eq "#788 dismissed{} beats regressed" "dismissed" \
  "$(rl_cp '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}' "$DIS_OV" | jq -r '.["lenient-verdict"].status')"
# declined record + later occ → regressed.
DECL_OV='{"schema_version":2,"patterns":{"tooling-gap":{"state":"declined","fixed_at":"2026-04-01T00:00:00Z","provenance":"x","meta_issues":[{"number":113,"url":"https://o/r/issues/113","state":"declined","closedAt":"2026-04-01T00:00:00Z"}]}},"dismissed":{}}'
assert_eq "#788 declined record + later occ → regressed" "regressed" \
  "$(rl_cp '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' "$DECL_OV" | jq -r '.["tooling-gap"].status')"
# filed precedence: a legacy audit fix predating a newer occurrence, PLUS a `filed`
# lifecycle record (fixed_at cleared) → filed, NOT regressed.
FILED_OV='{"schema_version":2,"patterns":{"lenient-verdict":{"state":"filed","fixed_at":null,"provenance":"x","meta_issues":[{"number":9,"url":"https://o/r/issues/9","state":"filed","closedAt":null}]}},"dismissed":{}}'
assert_eq "#788 filed record + legacy audit fix + newer occ → filed (precedence)" "filed" \
  "$(rl_cp '{"schema_version":2,"kind":"audit","pr":1,"merged_at":"2026-06-24T00:00:00Z","fixes_patterns":["lenient-verdict"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-07-01T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}' "$FILED_OV" | jq -r '.["lenient-verdict"].status')"
# no lifecycle record + legacy fix, no newer occ → fixed (falls through arms).
NOREC_OV='{"schema_version":2,"patterns":{},"dismissed":{}}'
assert_eq "#788 no record + legacy fix, no newer occ → fixed" "fixed" \
  "$(rl_cp '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-04-15T00:00:00Z","fixes_patterns":["doc-accuracy"]}' "$NOREC_OV" | jq -r '.["doc-accuracy"].status')"
# open: no record, no fix.
assert_eq "#788 no record, no fix → open" "open" \
  "$(rl_cp '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["other"]}' "$NOREC_OV" | jq -r '.other.status')"
# canonicalization: a non-canonical stored lifecycle key does not surface a phantom.
CANON_OV='{"schema_version":2,"patterns":{"Doc-Accuracy":{"state":"filed","fixed_at":null,"provenance":"x","meta_issues":[{"number":9,"url":"https://o/r/issues/9","state":"filed","closedAt":null}]}},"dismissed":{}}'
assert_eq "#788 non-canonical lifecycle key canonicalized (no phantom, reports filed)" "filed" \
  "$(rl_cp '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' "$CANON_OV" | jq -r '.["doc-accuracy"].status')"

# ── meta-issue.sh number-keyed lifecycle write ───────────────────────────────
printf '%s' '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$RL_TMP/mi.json"
printf 'body\n' > "$RL_TMP/mi-body.md"
cat > "$RL_TMP/gh-mi.sh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[]' ;;
  *"issue create"*) echo 'https://github.com/o/r/issues/777' ;;
  *"issue comment"*) echo ok ;;
  *"/labels"*) echo '{}' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$RL_TMP/gh-mi.sh"
DEVFLOW_GH="$RL_TMP/gh-mi.sh" bash "$RL_MI" --tag lenient-verdict --slug lenient-verdict --title T --body-file "$RL_TMP/mi-body.md" --overrides "$RL_TMP/mi.json" >/dev/null 2>&1
DEVFLOW_GH="$RL_TMP/gh-mi.sh" bash "$RL_MI" --tag lenient-verdict --slug lenient-verdict --title T --body-file "$RL_TMP/mi-body.md" --overrides "$RL_TMP/mi.json" >/dev/null 2>&1
assert_eq "#788 meta-issue two filings of same number keep one entry" "1" "$(jq -r '.patterns["lenient-verdict"].meta_issues | length' "$RL_TMP/mi.json")"
assert_eq "#788 meta-issue writes state=filed, no dismissed entry" "filed" "$(jq -r '.patterns["lenient-verdict"].state' "$RL_TMP/mi.json")"
# --slug grammar validation
DEVFLOW_GH="$RL_TMP/gh-mi.sh" bash "$RL_MI" --tag ok --slug 'bad slug' --title T --body-file "$RL_TMP/mi-body.md" --overrides "$RL_TMP/mi.json" >/dev/null 2>&1; RL_SLUG_RC=$?
assert_eq "#788 meta-issue rejects a non-slug --slug (non-zero exit)" "true" "$([ "$RL_SLUG_RC" -ne 0 ] && echo true || echo false)"

# ── actionable-patterns regressed bypass + liveness ──────────────────────────
# A regressed pattern with occurrence_count BELOW min_occurrences is still
# actionable (regressed bypasses the threshold).
printf '%s\n' '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' > "$RL_TMP/ap-r.jsonl"
printf '%s' "$DECL_OV" > "$RL_TMP/ap-ov.json"
cat > "$RL_TMP/gh-ap.sh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[]' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$RL_TMP/gh-ap.sh"
RL_APOUT="$(DEVFLOW_GH="$RL_TMP/gh-ap.sh" DEVFLOW_CONFIG_FILE="$REPO_ROOT/lib/test/fixtures/config.json" bash "$RL_AP" "$RL_TMP/ap-r.jsonl" "$RL_TMP/ap-ov.json" 2>/dev/null)"
assert_eq "#788 actionable: regressed pattern below min is still actionable (bypass)" "true" \
  "$(printf '%s' "$RL_APOUT" | jq 'any(.[]; .tag=="tooling-gap" and .status=="regressed")')"
# Liveness: eligible set empty while a fixed pattern recurs above min → warning.
# Build a view where the only pattern is `fixed` with occ>=2 (min): no eligible,
# but suppressed-but-recurring → liveness warning on stderr.
printf '%s\n' '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-01-01T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-01-02T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' > "$RL_TMP/live-r.jsonl"
printf '%s' '{"schema_version":2,"patterns":{"doc-accuracy":{"state":"fixed","fixed_at":"2027-01-01T00:00:00Z","provenance":"x","meta_issues":[{"number":9,"url":"https://o/r/issues/9","state":"fixed","closedAt":"2027-01-01T00:00:00Z"}]}},"dismissed":{}}' > "$RL_TMP/live-ov.json"
DEVFLOW_GH="$RL_TMP/gh-ap.sh" DEVFLOW_CONFIG_FILE="$REPO_ROOT/lib/test/fixtures/config.json" bash "$RL_AP" "$RL_TMP/live-r.jsonl" "$RL_TMP/live-ov.json" 2>"$RL_TMP/live.err" >/dev/null
assert_eq "#788 liveness: fixed-but-recurring with empty eligible set → ::warning::" "true" \
  "$(grep -q '::warning::actionable-patterns: no pattern is eligible' "$RL_TMP/live.err" && echo true || echo false)"
assert_eq "#788 liveness: warning names the highest suppressed slug" "true" \
  "$(grep -q 'doc-accuracy' "$RL_TMP/live.err" && echo true || echo false)"
# Negative case: a `filed` pattern (open meta-issue) recurring does NOT warn.
printf '%s' '{"schema_version":2,"patterns":{"doc-accuracy":{"state":"filed","fixed_at":null,"provenance":"x","meta_issues":[{"number":9,"url":"https://o/r/issues/9","state":"filed","closedAt":null}]}},"dismissed":{}}' > "$RL_TMP/live-ov2.json"
DEVFLOW_GH="$RL_TMP/gh-ap.sh" DEVFLOW_CONFIG_FILE="$REPO_ROOT/lib/test/fixtures/config.json" bash "$RL_AP" "$RL_TMP/live-r.jsonl" "$RL_TMP/live-ov2.json" 2>"$RL_TMP/live2.err" >/dev/null
assert_eq "#788 liveness: all-filed recurring set emits NO warning" "false" \
  "$(grep -q '::warning::actionable-patterns: no pattern is eligible' "$RL_TMP/live2.err" && echo true || echo false)"

# ── caps: open-count derivation + report rendering ───────────────────────────
# The cap counts are derived from `filed` lifecycle entries across records, never
# from a label query. A record with two `filed` entries and one `fixed` entry
# contributes 2 to max_open_issues and 2 to that category's max_open_per_category.
CAP_OV='{"schema_version":2,"patterns":{"a":{"state":"filed","fixed_at":null,"provenance":"x","meta_issues":[{"number":1,"url":"u","state":"filed","closedAt":null},{"number":2,"url":"u","state":"filed","closedAt":null},{"number":3,"url":"u","state":"fixed","closedAt":"2026-01-01T00:00:00Z"}]},"b":{"state":"filed","fixed_at":null,"provenance":"x","meta_issues":[{"number":4,"url":"u","state":"filed","closedAt":null}]}},"dismissed":{}}'
assert_eq "#788 caps: total open = filed entries across all records" "3" \
  "$(printf '%s' "$CAP_OV" | jq -r '[(.patterns // {})[] | (.meta_issues // [])[] | select(.state=="filed")] | length')"
assert_eq "#788 caps: per-category open = filed entries in one record" "2" \
  "$(printf '%s' "$CAP_OV" | jq -r '[.patterns["a"].meta_issues[]? | select(.state=="filed")] | length')"
# render-report names each withheld pattern with its cap.
( . "$REPO_ROOT/lib/render-report.sh"
  WSUM='{"prs_scanned":1,"clean_count":0,"analyzed_count":1,"withheld_patterns":[{"tag":"tooling-gap","cap":"max_issues_per_run"}]}'
  WREP="$(devflow_render_report "$WSUM")"
  assert_eq "#788 report: withheld section names the pattern" "true" \
    "$(printf '%s' "$WREP" | grep -q 'tooling-gap' && echo true || echo false)"
  assert_eq "#788 report: withheld section names the cap" "true" \
    "$(printf '%s' "$WREP" | grep -q 'max_issues_per_run' && echo true || echo false)" )

# ── real-corpus migrate-then-reconcile-then-derive integration ───────────────
# A v1 fixture shaped like this repo's real overrides.json (the loop's own dismissed
# entries for the 11 categories), with a stubbed gh returning the real issue states,
# asserts the lifecycle-record states after migrate+reconcile: dismissed{} holds no
# loop-written key, tooling-gap → declined (#113 NOT_PLANNED), the rest → fixed.
printf '%s' '{"schema_version":1,"dismissed":{
  "tooling-gap":{"dismissed_at":"2026-06-03T21:39:06Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/o/r/issues/113"},
  "fabricated-claim":{"dismissed_at":"2026-07-24T00:00:00Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/o/r/issues/761"},
  "doc-accuracy":{"dismissed_at":"2026-06-29T00:00:00Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/o/r/issues/183"}
}}' > "$RL_TMP/real.json"
cat > "$RL_TMP/gh-real.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then echo '[]'; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  case "$3" in
    113) echo '{"number":113,"state":"CLOSED","stateReason":"NOT_PLANNED","closedAt":"2026-06-28T21:24:43Z"}' ;;
    761) echo '{"number":761,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-07-24T10:11:25Z"}' ;;
    183) echo '{"number":183,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-06-30T00:00:00Z"}' ;;
    *) echo '{"number":'"$3"',"state":"OPEN","stateReason":null,"closedAt":null}' ;;
  esac
  exit 0
fi
exit 1
STUB
chmod +x "$RL_TMP/gh-real.sh"
DEVFLOW_GH="$RL_TMP/gh-real.sh" bash "$RL_PS" run "$RL_TMP/real.json" >/dev/null 2>&1
assert_eq "#788 real-corpus: dismissed{} holds no loop-written key" "0" "$(jq -r '.dismissed | length' "$RL_TMP/real.json")"
assert_eq "#788 real-corpus: tooling-gap record is declined" "declined" "$(jq -r '.patterns["tooling-gap"].state' "$RL_TMP/real.json")"
assert_eq "#788 real-corpus: fabricated-claim record is fixed" "fixed" "$(jq -r '.patterns["fabricated-claim"].state' "$RL_TMP/real.json")"
assert_eq "#788 real-corpus: doc-accuracy record is fixed" "fixed" "$(jq -r '.patterns["doc-accuracy"].state' "$RL_TMP/real.json")"
# Derived statuses after compute-patterns over the reconciled state: a slug whose
# newest occurrence post-dates its fixed_at → regressed (tooling-gap: declined #113
# closed 2026-06-28, occurrence after); fabricated-claim → fixed (issue closed
# after its last occurrence).
RC_ENTRIES='{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-07-01T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-07-23T17:32:23Z","verdict":"imperfect","categories":["fabricated-claim"]}'
RC_VIEW="$(rl_cp "$RC_ENTRIES" "$(cat "$RL_TMP/real.json")")"
assert_eq "#788 real-corpus derived: tooling-gap → regressed" "regressed" "$(printf '%s' "$RC_VIEW" | jq -r '.["tooling-gap"].status')"
assert_eq "#788 real-corpus derived: fabricated-claim → fixed" "fixed" "$(printf '%s' "$RC_VIEW" | jq -r '.["fabricated-claim"].status')"

# ────────────────────────────────────────────────────────────────────────────
# compute-patterns.jq — relocated from lib/test/run.sh (issue #788 AC).
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
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
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
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "v1 theme_tags + v2 categories grouped together (count=2)" \
  "2" \
  "$(echo "$RESULT" | jq -r '.["doc-accuracy"].occurrence_count')"

# One occ + later audit fix → status "fixed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-04-15T00:00:00Z","fixes_patterns":["lenient-verdict"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "occ then fix → status=fixed" \
  "fixed" \
  "$(echo "$RESULT" | jq -r '.["lenient-verdict"].status')"

# Successor-slug split (#129): each of the three slugs that replaced the removed
# coarse review/gate slug aggregates as its own pattern, and the removed slug
# never appears.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["outstanding-reject"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-05-02T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}
{"schema_version":2,"kind":"implementation","pr":3,"merged_at":"2026-05-03T00:00:00Z","verdict":"imperfect","categories":["deferred-verification"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "split slug outstanding-reject aggregates (count=1)" \
  "1" "$(echo "$RESULT" | jq -r '.["outstanding-reject"].occurrence_count')"
assert_eq "split slug lenient-verdict aggregates (count=1)" \
  "1" "$(echo "$RESULT" | jq -r '.["lenient-verdict"].occurrence_count')"
assert_eq "split slug deferred-verification aggregates (count=1)" \
  "1" "$(echo "$RESULT" | jq -r '.["deferred-verification"].occurrence_count')"
assert_eq "removed split slug never aggregates" \
  "null" "$(echo "$RESULT" | jq -r '.["review-gate" + "-bypass"].occurrence_count')"

# Boundary case: a gate-absent / human-authored PR (no review-related slug) maps to
# NONE of the three successor slugs.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":9,"merged_at":"2026-05-09T00:00:00Z","verdict":"imperfect","categories":["other"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "gate-absent PR → no outstanding-reject pattern" \
  "null" "$(echo "$RESULT" | jq -r '.["outstanding-reject"].occurrence_count')"
assert_eq "gate-absent PR → no lenient-verdict pattern" \
  "null" "$(echo "$RESULT" | jq -r '.["lenient-verdict"].occurrence_count')"
assert_eq "gate-absent PR → no deferred-verification pattern" \
  "null" "$(echo "$RESULT" | jq -r '.["deferred-verification"].occurrence_count')"


# Fix then later occ → status "regressed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"audit","pr":1,"merged_at":"2026-04-01T00:00:00Z","fixes_patterns":["convention-violation"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-15T00:00:00Z","verdict":"imperfect","categories":["convention-violation"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "fix then occ → status=regressed" \
  "regressed" \
  "$(echo "$RESULT" | jq -r '.["convention-violation"].status')"

# Override → status "dismissed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{"tooling-gap":{"reason":"meta-plugin-issue"}}}')
assert_eq "override → status=dismissed" \
  "dismissed" \
  "$(echo "$RESULT" | jq -r '.["tooling-gap"].status')"

# verdict:"blocked" entries also count as occurrences (alongside "imperfect").
# A simplification of the filter to drop "blocked" would silently make the
# whole "Blocked" workpad-status branch invisible to the audit.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"blocked","categories":["unmet-acceptance-criteria"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "blocked verdict counts as occurrence" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["unmet-acceptance-criteria"].occurrence_count')"

# Slug normalization is still applied defensively: a legacy mixed-case
# theme_tag slugifies to lowercase and matches a lowercase fixes_pattern.
RESULT=$(cp_run \
  '{"schema_version":1,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","theme_tags":["Foo-Bar-IN-Clause"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-04-15T00:00:00Z","fixes_patterns":["foo-bar-in-clause"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "slug normalization: mixed-case theme_tag matched by lowercase fixes_pattern → fixed" \
  "fixed" \
  "$(echo "$RESULT" | jq -r '.["foo-bar-in-clause"].status')"

# Missing merged_at MUST NOT contaminate first_seen/last_seen.
# An entry with no merged_at should be excluded from occurrences.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-15T00:00:00Z","verdict":"imperfect","categories":["other"]}
{"schema_version":2,"kind":"implementation","pr":2,"verdict":"imperfect","categories":["other"]}' \
  '{"schema_version":2,"patterns":{},"dismissed":{}}')
assert_eq "missing merged_at filtered out (count=1)" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["other"].occurrence_count')"
assert_eq "missing merged_at does not poison first_seen" \
  "2026-04-15T00:00:00Z" \
  "$(echo "$RESULT" | jq -r '.["other"].first_seen')"

# ────────────────────────────────────────────────────────────────────────────
# meta-issue.sh — relocated from lib/test/run.sh (issue #788 AC).
# ────────────────────────────────────────────────────────────────────────────

MI_TMP="$(mktemp -d)"
echo '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$MI_TMP/ov.json"
# #152: the body is the Stage-B-authored issue spec, filed VERBATIM. Use a body
# with backticks, $, and newlines to prove it round-trips unmangled (written to a
# file, never inlined into shell) and is NOT wrapped in any prepend/append.
printf '## Problem Statement\nStrengthen `cheap-gate.jq` so $VAR shapes do not slip.\n\nMulti-line.\n' > "$MI_TMP/body.md"
# Stub writes its capture files into its own dir ($MI_TMP) so a quoted heredoc can
# stay free of run.sh shell-var interpolation. Handles label create / issue edit
# (the best-effort label stamping) in addition to list/create/comment.
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
D="$(dirname "$0")"
case "$*" in
  *"issue list"*) echo '' ;;                                # no existing issue
  *"issue create"*)
     printf '%s' "$*" > "$D/create-args"
     prev=""
     for a in "$@"; do
       [ "$prev" = "--body-file" ] && cat "$a" > "$D/created-body.md"
       prev="$a"
     done
     echo 'https://github.com/acme/example-repo/issues/4242' ;;
  *"issue comment"*) echo 'commented' ;;
  *"issues/"*"/labels"*) printf '%s' "$*" > "$D/edit-args" ;;   # REST label apply (apply-labels.sh)
  *"--method POST"*"/labels"*) echo '{}' ;;                       # REST label create (ensure-label.sh)
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
# #152: the filed body equals the input verbatim — no `## Pattern:` prepend, no
# "can't be an auto-opened PR" boilerplate, backticks/$/newlines intact.
assert_eq "meta-issue files the body verbatim" "true" \
  "$(diff -q "$MI_TMP/body.md" "$MI_TMP/created-body.md" >/dev/null 2>&1 && echo true || echo false)"
# #152: both the DevFlow provenance label and the Retrospective marker are stamped
# (best-effort) on the freshly filed issue (#4242, derived from the created URL).
assert_eq "meta-issue stamps DevFlow label (REST labels[] field)" "true" \
  "$(grep -qF -- 'labels[]=DevFlow' "$MI_TMP/edit-args" && echo true || echo false)"
assert_eq "meta-issue stamps Retrospective label (REST labels[] field)" "true" \
  "$(grep -qF -- 'labels[]=Retrospective' "$MI_TMP/edit-args" && echo true || echo false)"
assert_eq "meta-issue applies via REST issues/4242/labels (not gh issue edit)" "true" \
  "$(grep -qF -- 'issues/4242/labels' "$MI_TMP/edit-args" && echo true || echo false)"
# #788: the filing records a `filed` lifecycle entry (number-keyed) on the slug's
# patterns[] record — NOT a `.dismissed` entry (that map is human-owned now).
assert_eq "lifecycle entry recorded with url" "https://github.com/acme/example-repo/issues/4242" "$(jq -r '.patterns["review-reject-bypassed"].meta_issues[0].url' "$MI_TMP/ov.json")"
assert_eq "lifecycle entry keyed by number"   "4242" "$(jq -r '.patterns["review-reject-bypassed"].meta_issues[0].number' "$MI_TMP/ov.json")"
assert_eq "lifecycle record state is filed"   "filed" "$(jq -r '.patterns["review-reject-bypassed"].state' "$MI_TMP/ov.json")"
assert_eq "filing writes NO dismissed entry"  "false" "$(jq -e '.dismissed | has("review-reject-bypassed")' "$MI_TMP/ov.json" >/dev/null 2>&1 && echo true || echo false)"
# existing-issue path (de-dup): comments instead of re-filing, still stamps labels
rm -f "$MI_TMP/edit-args"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
D="$(dirname "$0")"
case "$*" in
  *"issue list"*) echo '[{"number":99,"url":"https://github.com/acme/example-repo/issues/99","title":"[devflow-retrospective] meta: t-existing — x"}]' ;;
  *"issue comment"*) echo 'commented' ;;
  *"issues/"*"/labels"*) printf '%s' "$*" > "$D/edit-args" ;;   # REST label apply (apply-labels.sh)
  *"--method POST"*"/labels"*) echo '{}' ;;                       # REST label create (ensure-label.sh)
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
URL2="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag t-existing --slug t-existing --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov.json" 2>/dev/null)"
assert_eq "meta-issue reuses existing URL" "https://github.com/acme/example-repo/issues/99" "$URL2"
assert_eq "meta-issue stamps labels on the existing issue #99 (REST issues/99/labels)" "true" \
  "$(grep -qF -- 'issues/99/labels' "$MI_TMP/edit-args" && echo true || echo false)"
# #152: fail CLOSED on a create that returns no usable issue URL. `gh issue create`
# can exit 0 with empty/garbage stdout; without the URL-shape guard meta-issue.sh
# would report a phantom filing AND write a permanent overrides.json cooldown for
# an issue that never existed (the "never report unfiled as filed" invariant). The
# guard must exit non-zero so the orchestrator records a blocker, and must NOT have
# written a dismissal for the slug.
echo '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$MI_TMP/ov2.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;            # no existing issue → create path
  *"issue create"*) echo '' ;;          # exit 0 but NO url
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag empty-url --slug empty-url --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; EMPTY_RC=$?
assert_eq "meta-issue fails closed on empty create URL (non-zero exit)" "true" \
  "$([ "$EMPTY_RC" -ne 0 ] && echo true || echo false)"
assert_eq "meta-issue wrote NO lifecycle record on empty create URL" "false" \
  "$(jq -e '.patterns | has("empty-url")' "$MI_TMP/ov2.json" >/dev/null 2>&1 && echo true || echo false)"
# garbage (non-URL) stdout → same fail-closed
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;
  *"issue create"*) echo 'could not create issue: HTTP 403' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag garbage-url --slug garbage-url --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; GARBAGE_RC=$?
assert_eq "meta-issue fails closed on garbage create stdout (non-zero exit)" "true" \
  "$([ "$GARBAGE_RC" -ne 0 ] && echo true || echo false)"
# de-dup lookup failure (gh issue list non-zero) → exit 1 (orchestrator blocker trigger)
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) exit 1 ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag lookup-fail --slug lookup-fail --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; LOOKUP_RC=$?
assert_eq "meta-issue fails closed on de-dup lookup error (non-zero exit)" "true" \
  "$([ "$LOOKUP_RC" -ne 0 ] && echo true || echo false)"
# #152: de-dup lookup that exits 0 with a NON-JSON body (auth/upgrade warning on
# stdout, HTML error page) must fail CLOSED at the jq parse, not flow on as "no
# existing issue" and re-file a duplicate. Mirrors actionable-patterns.sh's
# non-JSON cooldown guard (the sibling consumer of the same gh contract).
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo 'gh: not authenticated' ;;   # exit 0 but non-JSON
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag nonjson-lookup --slug nonjson-lookup --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; NONJSON_RC=$?
assert_eq "meta-issue fails closed on a non-JSON de-dup body (non-zero exit)" "true" \
  "$([ "$NONJSON_RC" -ne 0 ] && echo true || echo false)"
# --dry-run: records the DRYRUN sentinel, invokes NO issue create / issue edit
echo '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$MI_TMP/ov3.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
D="$(dirname "$0")"
case "$*" in
  *"issue list"*) echo '' ;;
  *"issue create"*) echo "CREATE_CALLED" >> "$D/calls" ; echo '' ;;
  *"issue edit"*) echo "EDIT_CALLED" >> "$D/calls" ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
rm -f "$MI_TMP/calls"
DRY_URL="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --dry-run --tag dry --slug dry --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov3.json" 2>/dev/null)"
assert_eq "meta-issue --dry-run prints the DRYRUN sentinel" "https://example.invalid/issues/DRYRUN" "$DRY_URL"
assert_eq "meta-issue --dry-run invokes no gh create/edit" "true" \
  "$([ ! -f "$MI_TMP/calls" ] && echo true || echo false)"
# #152: de-dup HIT path also fails closed on a garbage url/number (gh --json drift
# emitting a null number/url) — mirrors the create-path guard.
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[{"number":null,"url":null,"title":"[devflow-retrospective] meta: dedup-null — x"}]' ;;   # contract drift: nulls
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag dedup-null --slug dedup-null --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; DEDUP_RC=$?
assert_eq "meta-issue fails closed on a de-dup hit with null url/number" "true" \
  "$([ "$DEDUP_RC" -ne 0 ] && echo true || echo false)"
# #152: the tokenized GitHub --search can surface an issue whose title does NOT
# literally carry `meta: ${TAG}` (a loose token hit). meta-issue.sh must STRICTLY
# re-parse the slug and reject the loose match — filing a NEW issue (create path)
# rather than commenting on / pinning the cooldown to the wrong issue. Here the
# only open issue's slug is `widget-foobar`; the requested tag is `widget` →
# no exact match → create path (returns the freshly created URL, not #88).
echo '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$MI_TMP/ov-loose.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[{"number":88,"url":"https://github.com/acme/example-repo/issues/88","title":"[devflow-retrospective] meta: widget-foobar — loose"}]' ;;
  *"issue create"*) echo 'https://github.com/acme/example-repo/issues/4343' ;;
  *"issue edit"*) : ;;
  *"label create"*) echo 'created' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
LOOSE_URL="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag widget --slug widget --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-loose.json" 2>/dev/null)"
assert_eq "meta-issue strict-rejects a loose --search slug match (files new, not #88)" "https://github.com/acme/example-repo/issues/4343" "$LOOSE_URL"
# #152: overrides-write failure AFTER a successful create reports FILED, not
# blocked — a corrupt overrides file makes the jq cooldown write fail, but the
# issue genuinely exists, so meta-issue.sh must exit 0 with the URL on stdout
# (the orchestrator records the filing) and leave a loud ::error:: breadcrumb;
# the open-issue de-dupe self-heals the missing cooldown next run. Reporting
# "not filed" here would lose a real issue.
printf 'not json{' > "$MI_TMP/ov-corrupt.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;
  *"issue create"*) echo 'https://github.com/acme/example-repo/issues/7777' ;;
  *"issue edit"*) : ;;
  *"label create"*) echo 'created' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
OVFAIL_OUT="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag ov-fail --slug ov-fail --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-corrupt.json" 2>"$MI_TMP/ov-fail.err")"; OVFAIL_RC=$?
assert_eq "meta-issue reports FILED on a cooldown-write failure (exit 0)" "true" \
  "$([ "$OVFAIL_RC" -eq 0 ] && echo true || echo false)"
assert_eq "meta-issue still prints the filed URL on a cooldown-write failure" "https://github.com/acme/example-repo/issues/7777" "$OVFAIL_OUT"
assert_eq "meta-issue leaves a 'WAS filed' breadcrumb on a cooldown-write failure" "true" \
  "$(grep -q 'issue WAS filed' "$MI_TMP/ov-fail.err" && echo true || echo false)"

# #152/#788: --dry-run must NOT mutate the real overrides.json — a dry run that
# records the DRYRUN sentinel as a lifecycle entry would make a later live run skip
# the real filing. The patterns map must stay empty after a dry run.
echo '{"schema_version":2,"patterns":{},"dismissed":{}}' > "$MI_TMP/ov-dry.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --dry-run --tag dry-ov --slug dry-ov --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-dry.json" >/dev/null 2>&1
assert_eq "meta-issue --dry-run writes NO lifecycle record to overrides" "false" \
  "$(jq -e '.patterns | has("dry-ov")' "$MI_TMP/ov-dry.json" >/dev/null 2>&1 && echo true || echo false)"

# #152: TAG carrying a GitHub search qualifier / whitespace is rejected at
# arg-parse (before it reaches the de-dupe --search), so a drift fails loud
# instead of mis-routing the lookup and re-filing a duplicate.
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag 'foo in:body' --slug foo --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-dry.json" >/dev/null 2>&1; BADTAG_RC=$?
assert_eq "meta-issue rejects a non-slug --tag (non-zero exit)" "true" \
  "$([ "$BADTAG_RC" -ne 0 ] && echo true || echo false)"
# #788: on a recurrence the Step-1 de-dupe hits the SAME open issue and re-runs the
# Step-2 write. The lifecycle entry is keyed by issue number, so the record must
# still hold exactly ONE meta-issue entry (no duplicate append that would exhaust
# max_open_per_category against one issue), and the record's `provenance` (first
# filing) must be PRESERVED rather than bumped forward.
printf '%s' '{"schema_version":2,"patterns":{"recur":{"state":"filed","fixed_at":null,"provenance":"2020-01-01T00:00:00Z","meta_issues":[{"number":55,"url":"https://github.com/acme/example-repo/issues/55","state":"filed","closedAt":null}]}},"dismissed":{}}' > "$MI_TMP/ov-recur.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[{"number":55,"url":"https://github.com/acme/example-repo/issues/55","title":"[devflow-retrospective] meta: recur — x"}]' ;;  # de-dup HIT
  *"issue comment"*) echo 'commented' ;;
  *"issues/"*"/labels"*) : ;;
  *"--method POST"*"/labels"*) echo '{}' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag recur --slug recur --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-recur.json" >/dev/null 2>&1
assert_eq "meta-issue recurrence keeps exactly one number-keyed entry" "1" \
  "$(jq -r '.patterns["recur"].meta_issues | length' "$MI_TMP/ov-recur.json")"
assert_eq "meta-issue preserves the original provenance on a recurrence" "2020-01-01T00:00:00Z" \
  "$(jq -r '.patterns["recur"].provenance' "$MI_TMP/ov-recur.json")"
rm -rf "$MI_TMP"

# ────────────────────────────────────────────────────────────────────────────
# filing-decisions.sh — the executable owner of the Step 8c cap decision and of
# the three report fields whose producers were missing (issue #788).
# ────────────────────────────────────────────────────────────────────────────
# Sourced inside a subshell, like run.sh's render-report.sh blocks, for two
# reasons: the helper carries `set -euo pipefail` (which must not leak into the
# harness — run.sh deliberately does not run under `set -e`), and a sourced file
# COMPLETING fires this module's own `trap ... RETURN`, which would delete
# $RL_TMP out from under every later assertion. `set +e` inside restores the
# harness's own semantics so one failing command cannot silently skip the rest
# of the block. assert_eq records through $RESULTS_FILE, so a subshell's results
# still count.
(
set +e
# shellcheck source=../../filing-decisions.sh
. "$REPO_ROOT/lib/filing-decisions.sh"
set +e

# Cap arms, in the order the helper evaluates them. Each row drives ONE arm with
# every other cap slack, so a mis-ordered check changes exactly one expectation.
assert_eq "#788 caps: per-run cap withholds" "max_issues_per_run" \
  "$(devflow_filing_cap_verdict open 3 3 0 2 0 10)"
assert_eq "#788 caps: per-category cap withholds" "max_open_per_category" \
  "$(devflow_filing_cap_verdict open 0 3 2 2 0 10)"
assert_eq "#788 caps: total-open cap withholds a non-regressed pattern" "max_open_issues" \
  "$(devflow_filing_cap_verdict open 0 3 0 2 10 10)"
assert_eq "#788 caps: nothing withholds → file" "file" \
  "$(devflow_filing_cap_verdict open 0 3 0 2 0 10)"
# The regressed bypass, and its two limits: it bypasses max_open_issues ONLY.
assert_eq "#788 caps: regressed bypasses max_open_issues" "file" \
  "$(devflow_filing_cap_verdict regressed 0 3 0 2 10 10)"
assert_eq "#788 caps: regressed still honours max_issues_per_run" "max_issues_per_run" \
  "$(devflow_filing_cap_verdict regressed 3 3 0 2 0 10)"
assert_eq "#788 caps: regressed still honours max_open_per_category" "max_open_per_category" \
  "$(devflow_filing_cap_verdict regressed 0 3 2 2 0 10)"
# Arm ORDER: with the per-run cap AND the per-category cap both breached, the
# per-run cap must be the reported one. A swapped pair flips this value while
# every single-arm row above stays green.
assert_eq "#788 caps: per-run is evaluated before per-category" "max_issues_per_run" \
  "$(devflow_filing_cap_verdict open 3 3 2 2 0 10)"
assert_eq "#788 caps: per-category is evaluated before total-open" "max_open_per_category" \
  "$(devflow_filing_cap_verdict open 0 3 2 2 10 10)"
# Fail-closed: an underived count withholds rather than filing on unknown input.
assert_eq "#788 caps: empty count fails closed (withholds)" "invalid-operand" \
  "$(devflow_filing_cap_verdict open "" 3 0 2 0 10)"
assert_eq "#788 caps: non-numeric count fails closed (withholds)" "invalid-operand" \
  "$(devflow_filing_cap_verdict open abc 3 0 2 0 10)"
assert_eq "#788 caps: wrong argument count fails closed (withholds)" "invalid-operand" \
  "$(devflow_filing_cap_verdict open 0 3)"

# Liveness capture: the `liveness:` line actionable-patterns.sh writes to stderr
# is what the report's liveness line renders from.
printf 'noise\n::warning::actionable-patterns: something\nliveness: 3 suppressed-but-recurring pattern(s), highest foo\n' > "$RL_TMP/live.err"
assert_eq "#788 liveness: the stderr line is extracted for the report" \
  "3 suppressed-but-recurring pattern(s), highest foo" \
  "$(devflow_liveness_warning "$RL_TMP/live.err")"
printf 'noise only\n::warning::unrelated\n' > "$RL_TMP/noliveness.err"
assert_eq "#788 liveness: a run that emitted none yields empty (section omitted)" "" \
  "$(devflow_liveness_warning "$RL_TMP/noliveness.err")"
assert_eq "#788 liveness: an absent capture file yields empty, not an abort" "" \
  "$(devflow_liveness_warning "$RL_TMP/does-not-exist.err")"

# Won't-fix re-raise: only a NOT_PLANNED closure qualifies. DUPLICATE is also a
# `declined` transition but records no won't-fix judgement to re-raise.
printf '%s' '{"schema_version":2,"patterns":{"np":{"state":"declined","meta_issues":[{"number":1,"state":"declined","state_reason":"NOT_PLANNED"}]},"dup":{"state":"declined","meta_issues":[{"number":2,"state":"declined","state_reason":"DUPLICATE"}]},"done":{"state":"fixed","meta_issues":[{"number":3,"state":"fixed","state_reason":"COMPLETED"}]}},"dismissed":{}}' > "$RL_TMP/refiled.json"
assert_eq "#788 re-raise: a NOT_PLANNED closure is named" '["np"]' \
  "$(devflow_declined_refiled "$RL_TMP/refiled.json" '["np","dup","done"]')"
assert_eq "#788 re-raise: a DUPLICATE closure is NOT named" '[]' \
  "$(devflow_declined_refiled "$RL_TMP/refiled.json" '["dup"]')"
assert_eq "#788 re-raise: a pattern not filed this run is not named" '[]' \
  "$(devflow_declined_refiled "$RL_TMP/refiled.json" '[]')"
assert_eq "#788 re-raise: an unreadable overrides file yields [] (section omitted)" '[]' \
  "$(devflow_declined_refiled "$RL_TMP/no-such-overrides.json" '["np"]')"

# Per-pattern filing outcome / withheld_by on the unfiltered view.
printf '%s' '[{"tag":"filed-one","occurrence_count":5,"status":"regressed"},{"tag":"held","occurrence_count":2,"status":"open"},{"tag":"quiet","occurrence_count":1,"status":"open"}]' > "$RL_TMP/pfull.json"
RL_ANN="$(devflow_annotate_patterns "$RL_TMP/pfull.json" '["filed-one"]' '[{"tag":"held","cap":"max_open_issues"}]')"
assert_eq "#788 annotate: a filed pattern carries filing_outcome" "issue filed" \
  "$(printf '%s' "$RL_ANN" | jq -r '.[] | select(.tag=="filed-one") | .filing_outcome')"
assert_eq "#788 annotate: a withheld pattern carries the cap that withheld it" "max_open_issues" \
  "$(printf '%s' "$RL_ANN" | jq -r '.[] | select(.tag=="held") | .withheld_by')"
assert_eq "#788 annotate: a withheld pattern does not also say 'withheld' twice" "null" \
  "$(printf '%s' "$RL_ANN" | jq -r '.[] | select(.tag=="held") | .filing_outcome')"
assert_eq "#788 annotate: an untouched pattern still carries an outcome" "not filed" \
  "$(printf '%s' "$RL_ANN" | jq -r '.[] | select(.tag=="quiet") | .filing_outcome')"
assert_eq "#788 annotate: every pattern in the view survives the join" "3" \
  "$(printf '%s' "$RL_ANN" | jq -r 'length')"

# ── End-to-end: a real Step-9 summary renders every section ──────────────────
# This is the assertion that would have caught the dead wiring: it drives
# render-report.sh from a summary built by the SAME producers Step 9 calls,
# rather than from a hand-built fixture that supplies the keys directly.
(
  . "$REPO_ROOT/lib/render-report.sh"
  RL_SUM="$(jq -nc \
    --argjson patterns "$RL_ANN" \
    --arg liveness_warning "$(devflow_liveness_warning "$RL_TMP/live.err")" \
    --argjson declined_refiled "$(devflow_declined_refiled "$RL_TMP/refiled.json" '["np"]')" \
    --argjson withheld_patterns '[{"tag":"held","cap":"max_open_issues"}]' \
    '{prs_scanned:1,clean_count:0,analyzed_count:1,patterns:$patterns,
      liveness_warning:$liveness_warning,declined_refiled:$declined_refiled,
      withheld_patterns:$withheld_patterns}')"
  RL_OUT="$(devflow_render_report "$RL_SUM")"
  assert_eq "#788 e2e: the liveness section renders from the Step-6 capture" "true" \
    "$(case "$RL_OUT" in *"## Liveness warning"*"highest foo"*) echo true ;; *) echo false ;; esac)"
  assert_eq "#788 e2e: the won't-fix re-raised section names the pattern" "true" \
    "$(case "$RL_OUT" in *"Won't-fix patterns re-raised this run"*'`np`'*) echo true ;; *) echo false ;; esac)"
  assert_eq "#788 e2e: the per-pattern filing outcome renders inline" "true" \
    "$(case "$RL_OUT" in *'`filed-one`'*"issue filed"*) echo true ;; *) echo false ;; esac)"
  assert_eq "#788 e2e: the per-pattern withholding cap renders inline" "true" \
    "$(case "$RL_OUT" in *'`held`'*"withheld by \`max_open_issues\`"*) echo true ;; *) echo false ;; esac)"
  # Negative control on the same shape: a summary whose producers yielded nothing
  # omits both optional sections, so the assertions above pin real content rather
  # than a section header that is always present.
  RL_EMPTY="$(devflow_render_report '{"prs_scanned":1,"patterns":[],"liveness_warning":"","declined_refiled":[]}')"
  assert_eq "#788 e2e: no liveness capture → the section is omitted" "false" \
    "$(case "$RL_EMPTY" in *"## Liveness warning"*) echo true ;; *) echo false ;; esac)"
  assert_eq "#788 e2e: no re-raised pattern → the section is omitted" "false" \
    "$(case "$RL_EMPTY" in *"Won't-fix patterns re-raised"*) echo true ;; *) echo false ;; esac)"
)
)

# ── Remaining coverage gaps raised in review ────────────────────────────────
# state_reason is what distinguishes a won't-fix (NOT_PLANNED) from a duplicate
# closure downstream, so the reconciler must record it per entry, not just the
# `declined` state both closures share.
printf '%s' "$(rl_record np-reason 502)" > "$RL_TMP/sr1.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/sr1.json" >/dev/null 2>&1
assert_eq "#788 reconcile: a NOT_PLANNED entry records its state_reason" "NOT_PLANNED" \
  "$(jq -r '.patterns["np-reason"].meta_issues[0].state_reason' "$RL_TMP/sr1.json")"
printf '%s' "$(rl_record dup-reason 503)" > "$RL_TMP/sr2.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/sr2.json" >/dev/null 2>&1
assert_eq "#788 reconcile: a DUPLICATE entry records its own distinct state_reason" "DUPLICATE" \
  "$(jq -r '.patterns["dup-reason"].meta_issues[0].state_reason' "$RL_TMP/sr2.json")"
# An entry that reopens must not keep a stale closure reason: state_reason is
# cleared on the OPEN arm, so a later read cannot see a won't-fix that no longer
# holds.
printf '%s' '{"schema_version":2,"patterns":{"reopened":{"state":"declined","fixed_at":"2026-06-02T00:00:00Z","provenance":null,"meta_issues":[{"number":504,"url":"https://o/r/issues/504","state":"declined","closedAt":"2026-06-02T00:00:00Z","state_reason":"NOT_PLANNED"}]}},"dismissed":{}}' > "$RL_TMP/sr3.json"
DEVFLOW_GH="$RL_TMP/gh-view.sh" bash "$RL_PS" reconcile "$RL_TMP/sr3.json" >/dev/null 2>&1
assert_eq "#788 reconcile: reopening an entry clears its stale state_reason" "null" \
  "$(jq -r '.patterns["reopened"].meta_issues[0].state_reason' "$RL_TMP/sr3.json")"

# Prefetch HIT path: every reconcile assertion above runs against a stub whose
# `issue list` returns [], so only the by-number fallback leg is exercised. This
# stub answers the prefetch instead and makes `issue view` FAIL, so a transition
# here can only have come from the prefetch — the primary leg, otherwise
# untested. (Attributing the leg is the point: without the failing `view`, a
# broken prefetch would silently fall back and the assertion would stay green.)
cat > "$RL_TMP/gh-prefetch.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  echo '[{"number":601,"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-06-11T00:00:00Z"},{"number":602,"state":"OPEN","stateReason":null,"closedAt":null}]'
  exit 0
fi
# The fallback leg must NOT be able to satisfy these — any transition below is
# attributable to the prefetch alone.
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then echo 'prefetch-test: view must not be reached' >&2; exit 1; fi
exit 1
STUB
chmod +x "$RL_TMP/gh-prefetch.sh"
printf '%s' "$(rl_record prefetch-closed 601)" > "$RL_TMP/pf1.json"
DEVFLOW_GH="$RL_TMP/gh-prefetch.sh" bash "$RL_PS" reconcile "$RL_TMP/pf1.json" >/dev/null 2>&1
assert_eq "#788 prefetch hit: a COMPLETED row transitions from the prefetch alone" "fixed" \
  "$(jq -r '.patterns["prefetch-closed"].state' "$RL_TMP/pf1.json")"
assert_eq "#788 prefetch hit: fixed_at comes from the prefetch row's closedAt" "2026-06-11T00:00:00Z" \
  "$(jq -r '.patterns["prefetch-closed"].fixed_at' "$RL_TMP/pf1.json")"
# Positive control on the same fixture+stub: a slug the prefetch page does NOT
# cover makes no transition here, because the fallback leg is unavailable. This
# is what proves the two assertions above were satisfied by the prefetch rather
# than by a permissive stub answering everything.
printf '%s' "$(rl_record prefetch-missing 999)" > "$RL_TMP/pf2.json"
DEVFLOW_GH="$RL_TMP/gh-prefetch.sh" bash "$RL_PS" reconcile "$RL_TMP/pf2.json" >/dev/null 2>&1
assert_eq "#788 prefetch miss + unavailable fallback → no transition (control)" "filed" \
  "$(jq -r '.patterns["prefetch-missing"].state' "$RL_TMP/pf2.json")"

# NOTE (deliberately untested): actionable-patterns.sh's `_ELIGIBLE_N` guard is
# defense-in-depth for a path that is UNREACHABLE through the script's own
# control flow — the `OUTPUT="$( ... )" || { ...; exit 1; }` assignment above it
# terminates the run when jq fails, and a jq that succeeds always prints an
# array, so `$OUTPUT` is never empty-with-rc-0 at that point. A test asserting
# the guard would be vacuous (verified: it stays green against a mutant that
# removes the guard entirely), so none is written here rather than banking a
# passing assertion that proves nothing. If a future edit makes `$OUTPUT`
# reachable while empty, that edit owns the test.

# ── AC 76 evidence: run.sh is shorter than at this change's merge-base ───────
# Reported, not checked in: a hard-coded figure would rot as run.sh moves under
# other work, so the reduction is evidenced by this green run instead.
RL_BASE="$(git -C "$REPO_ROOT" merge-base origin/main HEAD 2>/dev/null || true)"
[ -n "$RL_BASE" ] || RL_BASE="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"
if [ -n "$RL_BASE" ]; then
  RL_BEFORE="$(git -C "$REPO_ROOT" show "$RL_BASE:lib/test/run.sh" 2>/dev/null | grep -c '')"
  RL_AFTER="$(grep -c '' "$REPO_ROOT/lib/test/run.sh")"
  echo "  #788 AC76: lib/test/run.sh ${RL_BEFORE} lines at merge-base → ${RL_AFTER} now"
  assert_eq "#788 AC76: run.sh is shorter than at the merge-base (${RL_BEFORE} → ${RL_AFTER})" "true" \
    "$( [ "${RL_BEFORE:-0}" -gt 0 ] && [ "${RL_AFTER:-0}" -lt "${RL_BEFORE:-0}" ] && echo true || echo false)"
else
  # No base ref to measure against is an unestablished comparison, not a pass.
  assert_eq "#788 AC76: run.sh line-count comparison could not resolve a base ref" "true" "false"
fi

rm -rf "$RL_TMP"
trap - RETURN
