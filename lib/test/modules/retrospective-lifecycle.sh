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

rm -rf "$RL_TMP"
trap - RETURN
