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
# Runner: discover and call every test_* function.
# ────────────────────────────────────────────────────────────────────────────
for _fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "$_fn"
  "$_fn"
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
