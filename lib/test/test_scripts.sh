#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Bash test harness for devflow shell scripts.
#
# Run from repo root:
#   bash lib/test/test_scripts.sh
#
# Summary line format: "<P> passed, <F> failed"
# (parsed by run.sh via: awk '/passed,/ { p=$1; f=$3 }')

set -u

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' \
      "$name" "$expected" "$actual"
  fi
}

assert_true() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n         command returned non-zero: %s\n' "$name" "$cmd"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
test_config_get() {
  local cfg; cfg="$(mktemp)"
  printf '%s' '{"a":{"b":"v"},"list":["x","y"],"n":5,"nul":null}' >"$cfg"
  assert_eq "scalar"      "v"   "$(scripts/config-get.sh .a.b '' "$cfg")"
  assert_eq "array-join"  "x,y" "$(scripts/config-get.sh .list '' "$cfg")"
  assert_eq "number"      "5"   "$(scripts/config-get.sh .n '' "$cfg")"
  assert_eq "leading-dot-optional" "v" "$(scripts/config-get.sh a.b '' "$cfg")"
  assert_eq "missing-uses-default" "D" "$(scripts/config-get.sh .a.zzz D "$cfg")"
  assert_eq "null-uses-default"    "D" "$(scripts/config-get.sh .nul D "$cfg")"
  assert_eq "scalar-midpath-empty" "D" "$(scripts/config-get.sh .n.x D "$cfg")"
  # An explicit empty-string default IS a default → exit 0 with empty stdout
  # (matches the original node behavior and lib/test/run.sh's cg test).
  local out rc
  out="$(scripts/config-get.sh .a.zzz "" "$cfg")"; rc=$?
  assert_eq "empty-default-rc0" "0" "$rc"
  assert_eq "empty-default-out" ""  "$out"
  # No default at all + absent key/file → exit 1.
  scripts/config-get.sh .nope.absent.key >/dev/null 2>&1
  assert_eq "no-default-rc1" "1" "$?"
  rm -f "$cfg"
}

# ────────────────────────────────────────────────────────────────────────────
test_branch_for_issue() {
  # Platform note: on this WSL2 machine, `iconv -f UTF-8 -t ASCII//TRANSLIT`
  # maps 'Café' → 'Cafe' (TRANSLIT substitution, not NFKD drop).
  # Python uses NFKD normalization which also yields 'Cafe' for é.
  # Both agree here, so the test expectation is 'cafe'.
  # (If iconv fell back to the tr-strip path it would give 'caf'; that's not
  #  the case on this machine.)

  # 1. Normal title → issue-12-add-login
  assert_eq "normal-title" \
    "issue-12-add-login" \
    "$(scripts/branch-for-issue.sh 12 'Add Login')"

  # 2. Empty/punct-only title → slug is empty → issue-7
  assert_eq "punct-only-title" \
    "issue-7" \
    "$(scripts/branch-for-issue.sh 7 '!!!')"

  # 3. Unicode title: 'Café latte' → iconv gives 'Cafe latte' → slug 'cafe-latte'
  assert_eq "unicode-cafe" \
    "issue-5-cafe-latte" \
    "$(scripts/branch-for-issue.sh 5 'Café latte')"

  # 4. Long title: slug > 50 chars → truncate at hyphen boundary (last hyphen > 20)
  #    'Add login page for users and make it beautiful and well-designed and accessible'
  #    slug = 'add-login-page-for-users-and-make-it-beautiful-and-well-designed-and-accessible'
  #    cut at 50 = 'add-login-page-for-users-and-make-it-beautiful-and'
  #    last hyphen > 20 → cut to 'add-login-page-for-users-and-make-it-beautiful' (46)
  #    branch = 'issue-1-add-login-page-for-users-and-make-it-beautiful'
  #    assert total length ≤ 59 (= len('issue-1-') + 50 + 1)
  local long_branch
  long_branch="$(scripts/branch-for-issue.sh 1 'Add login page for users and make it beautiful and well-designed and accessible')"
  assert_eq "long-title-exact" \
    "issue-1-add-login-page-for-users-and-make-it-beautiful" \
    "$long_branch"
  assert_true "long-title-len-le59" "[ ${#long_branch} -le 59 ]"

  # 5. --title-file: verify file reading with strip (leading/trailing whitespace removed)
  local tf; tf="$(mktemp)"
  printf '  Add login  \n' >"$tf"
  assert_eq "title-file" \
    "issue-3-add-login" \
    "$(scripts/branch-for-issue.sh 3 --title-file "$tf")"
  rm -f "$tf"

  # 6. Bad args: no title source → exit 2
  scripts/branch-for-issue.sh 9 >/dev/null 2>&1; local rc=$?
  assert_eq "no-title-exit2" "2" "$rc"

  # 7. Non-integer number → exit 2
  scripts/branch-for-issue.sh abc 'title' >/dev/null 2>&1; local rc2=$?
  assert_eq "non-int-number-exit2" "2" "$rc2"

  # 8. Both title sources provided → exit 2 (python errors; we reject extra args)
  local tf2; tf2="$(mktemp)"; printf 'x\n' >"$tf2"
  scripts/branch-for-issue.sh 1 'title' --title-file "$tf2" >/dev/null 2>&1
  assert_eq "both-sources-exit2" "2" "$?"
  rm -f "$tf2"
}

# ────────────────────────────────────────────────────────────────────────────
test_parse_acs() {
  local SCRIPT="scripts/parse-acs.sh"

  # ── post-merge probe (true positives) ──────────────────────────────────────
  assert_eq "post-merge: workflow run" "1" \
    "$("$SCRIPT" --post-merge-probe "Check the artifact link in the workflow run")"
  assert_eq "post-merge: on a live pr" "1" \
    "$("$SCRIPT" --post-merge-probe "Verify the workflow runs on a live PR")"
  assert_eq "post-merge: on a pr" "1" \
    "$("$SCRIPT" --post-merge-probe "Comment /screenshot on a PR and confirm")"
  assert_eq "post-merge: on a real pr" "1" \
    "$("$SCRIPT" --post-merge-probe "Trigger the bot on a real PR")"
  assert_eq "post-merge: comment on the pr" "1" \
    "$("$SCRIPT" --post-merge-probe "After merge, comment on the PR to retest")"
  assert_eq "post-merge: comment on a pr" "1" \
    "$("$SCRIPT" --post-merge-probe "Maintainer should comment on a PR with /screenshot")"
  assert_eq "post-merge: after merge" "1" \
    "$("$SCRIPT" --post-merge-probe "do X after merge")"
  assert_eq "post-merge: in production" "1" \
    "$("$SCRIPT" --post-merge-probe "verify in production environment")"

  # ── post-merge probe (false positives — must NOT match) ────────────────────
  assert_eq "NOT post-merge: monitoring substring" "0" \
    "$("$SCRIPT" --post-merge-probe "Sentry error monitoring is configured")"
  assert_eq "NOT post-merge: no trigger phrase" "0" \
    "$("$SCRIPT" --post-merge-probe "Errors must not be silently swallowed")"
  assert_eq "NOT post-merge: click substring" "0" \
    "$("$SCRIPT" --post-merge-probe "Add unit tests for the click handler")"
  assert_eq "NOT post-merge: workflow runner not workflow run" "0" \
    "$("$SCRIPT" --post-merge-probe "Document the CI workflow runner image")"
  assert_eq "NOT post-merge: commenting on a (no pr phrase)" "0" \
    "$("$SCRIPT" --post-merge-probe "Note: this is commenting on a previous decision")"
  assert_eq "NOT post-merge: one-click does not trigger click" "0" \
    "$("$SCRIPT" --post-merge-probe "one-click checkout flow")"

  # ── section extraction + checkbox parse ───────────────────────────────────
  local bf; bf="$(mktemp)"
  cat >"$bf" <<'BODY'
## Summary
intro text

## Acceptance Criteria
- [ ] first
- [x] second done
* [ ] star bullet
not a checkbox line
#### sub-note (deeper heading — must NOT terminate the section)
- [ ] after subheading

## Notes
- [ ] should not appear
BODY

  local md_out
  md_out="$("$SCRIPT" --body-file "$bf" --format md)"

  # 4 checkbox items expected
  local count; count="$(printf '%s\n' "$md_out" | grep -c '^- \[')"
  assert_eq "extract: 4 AC checkboxes (deeper heading does not terminate)" "4" "$count"

  assert_true "extract: first item present" \
    "printf '%s\n' \"\$md_out\" | grep -qFe '- [ ] first'"
  assert_true "extract: second item ticked" \
    "printf '%s\n' \"\$md_out\" | grep -qFe '- [x] second done'"
  assert_true "extract: star bullet parsed" \
    "printf '%s\n' \"\$md_out\" | grep -qFe '- [ ] star bullet'"
  assert_true "extract: Notes section excluded" \
    "! printf '%s\n' \"\$md_out\" | grep -qFe 'should not appear'"

  # ── case-insensitive heading match ────────────────────────────────────────
  local bf_lower; bf_lower="$(mktemp)"
  sed 's/## Acceptance Criteria/## acceptance criteria/' "$bf" >"$bf_lower"
  local count_lower; count_lower="$("$SCRIPT" --body-file "$bf_lower" --format md | grep -c '^- \[')"
  assert_eq "extract: lowercase heading matches (case-insensitive)" "4" "$count_lower"
  rm -f "$bf_lower"

  local bf_upper; bf_upper="$(mktemp)"
  sed 's/## Acceptance Criteria/## ACCEPTANCE CRITERIA/' "$bf" >"$bf_upper"
  local count_upper; count_upper="$("$SCRIPT" --body-file "$bf_upper" --format md | grep -c '^- \[')"
  assert_eq "extract: uppercase heading matches (case-insensitive)" "4" "$count_upper"
  rm -f "$bf_upper"

  # ── trailing-colon heading → zero items (near-miss, sentinel output) ───────
  local bf_colon; bf_colon="$(mktemp)"
  sed 's/## Acceptance Criteria/## Acceptance Criteria:/' "$bf" >"$bf_colon"
  local sentinel_out; sentinel_out="$("$SCRIPT" --body-file "$bf_colon" --format md 2>/dev/null)"
  assert_eq "extract: trailing-colon heading → sentinel" \
    '_(none provided in issue body)_' "$sentinel_out"
  rm -f "$bf_colon"

  # ── level-3 heading matches ────────────────────────────────────────────────
  local bf_l3; bf_l3="$(mktemp)"
  printf '### Acceptance Criteria\n- [ ] x\n' >"$bf_l3"
  local count_l3; count_l3="$("$SCRIPT" --body-file "$bf_l3" --format md | grep -c '^- \[')"
  assert_eq "extract: level-3 heading matches" "1" "$count_l3"
  rm -f "$bf_l3"

  # ── level-4 heading does NOT match ────────────────────────────────────────
  local bf_l4; bf_l4="$(mktemp)"
  printf '#### Acceptance Criteria\n- [ ] x\n' >"$bf_l4"
  local sentinel_l4; sentinel_l4="$("$SCRIPT" --body-file "$bf_l4" --format md 2>/dev/null)"
  assert_eq "extract: level-4 heading not matched" \
    '_(none provided in issue body)_' "$sentinel_l4"
  rm -f "$bf_l4"

  # ── sentinel when no sections ──────────────────────────────────────────────
  local bf_empty; bf_empty="$(mktemp)"
  printf '## Summary\nno criteria here\n' >"$bf_empty"
  assert_eq "render_md: empty → sentinel" \
    '_(none provided in issue body)_' \
    "$("$SCRIPT" --body-file "$bf_empty" --format md 2>/dev/null)"
  rm -f "$bf_empty"

  # ── post-merge tag appended in md output ──────────────────────────────────
  local bf_pm; bf_pm="$(mktemp)"
  printf '## Acceptance Criteria\n- [ ] do X after merge\n' >"$bf_pm"
  local pm_out; pm_out="$("$SCRIPT" --body-file "$bf_pm" --format md)"
  assert_true "render_md: post-merge tag appended" \
    "printf '%s\n' \"\$pm_out\" | grep -qF '(post-merge)'"
  rm -f "$bf_pm"

  # ── no double post-merge tag ───────────────────────────────────────────────
  local bf_dbl; bf_dbl="$(mktemp)"
  printf '## Acceptance Criteria\n- [x] already (post-merge)\n' >"$bf_dbl"
  local dbl_out; dbl_out="$("$SCRIPT" --body-file "$bf_dbl" --format md)"
  local dbl_count; dbl_count="$(printf '%s\n' "$dbl_out" | grep -o '(post-merge)' | wc -l | tr -d ' ')"
  assert_eq "render_md: no double post-merge tag" "1" "$dbl_count"
  rm -f "$bf_dbl"

  # ── ticked box rendered with [x] ──────────────────────────────────────────
  local bf_tick; bf_tick="$(mktemp)"
  printf '## Acceptance Criteria\n- [x] done item\n' >"$bf_tick"
  local tick_out; tick_out="$("$SCRIPT" --body-file "$bf_tick" --format md)"
  assert_true "render_md: ticked box rendered" \
    "printf '%s\n' \"\$tick_out\" | grep -qFe '- [x] done item'"
  rm -f "$bf_tick"

  # ── test plan appended after blank line ───────────────────────────────────
  local bf_tp; bf_tp="$(mktemp)"
  cat >"$bf_tp" <<'TPBODY'
## Acceptance Criteria
- [ ] a

## Test Plan
- [ ] b
TPBODY
  local tp_out; tp_out="$("$SCRIPT" --body-file "$bf_tp" --format md)"
  assert_true "render_md: test plan appended after blank line" \
    "printf '%s\n' \"\$tp_out\" | grep -qE '^\$' && printf '%s\n' \"\$tp_out\" | grep -qFe '- [ ] b'"
  rm -f "$bf_tp"

  # ── json format: correct keys via jq ──────────────────────────────────────
  local bf_json; bf_json="$(mktemp)"
  cat >"$bf_json" <<'JSONBODY'
## Acceptance Criteria
- [ ] check one
- [x] check two
JSONBODY
  local json_out; json_out="$("$SCRIPT" --body-file "$bf_json" --format json)"
  assert_true "json: acceptance_criteria key exists" \
    "printf '%s\n' \"\$json_out\" | jq -e '.acceptance_criteria' >/dev/null 2>&1"
  assert_true "json: test_plan key exists" \
    "printf '%s\n' \"\$json_out\" | jq -e '.test_plan' >/dev/null 2>&1"
  assert_true "json: first item has text field" \
    "printf '%s\n' \"\$json_out\" | jq -e '.acceptance_criteria[0].text' >/dev/null 2>&1"
  assert_true "json: first item has ticked field" \
    "printf '%s\n' \"\$json_out\" | jq -e '.acceptance_criteria[0].ticked == false' >/dev/null 2>&1"
  assert_true "json: second item ticked true" \
    "printf '%s\n' \"\$json_out\" | jq -e '.acceptance_criteria[1].ticked == true' >/dev/null 2>&1"
  assert_true "json: first item has post_merge field" \
    "printf '%s\n' \"\$json_out\" | jq -e 'has(\"acceptance_criteria\") and (.acceptance_criteria[0] | has(\"post_merge\"))' >/dev/null 2>&1"
  rm -f "$bf_json"

  # ── bad args: exit 2 ──────────────────────────────────────────────────────
  "$SCRIPT" --format md >/dev/null 2>&1
  assert_eq "bad-args: no source → exit 2" "2" "$?"
  "$SCRIPT" --issue 1 --body-file /dev/null >/dev/null 2>&1
  assert_eq "bad-args: both sources → exit 2" "2" "$?"

  rm -f "$bf"
}

# ────────────────────────────────────────────────────────────────────────────
# Runner: discover and call every test_* function.
# ────────────────────────────────────────────────────────────────────────────
for _fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "$_fn"
  "$_fn"
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
