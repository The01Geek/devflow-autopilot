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
# Runner: discover and call every test_* function.
# ────────────────────────────────────────────────────────────────────────────
for _fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "$_fn"
  "$_fn"
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
