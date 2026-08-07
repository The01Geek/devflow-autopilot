#!/bin/bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# `declare -A` is Bash 4 only. Under Bash 3.2 `declare -A m` is an invalid option and
# `m[key]=v` then assigns into an INDEXED array at index 0 — so a helper keyed by
# strings silently collapses every key onto one slot instead of failing. That silent
# collapse is why `lib/test/module-harness.sh` is registered `excluded` rather than
# being "fixed": its worker pool is genuinely built on this feature.
#
# Exit 0 = the interpreter refuses `declare -A` (it is 3.2-shaped).
# Exit 1 = it accepted it (a Bash 4+ interpreter).
set -u

if "$BASH" -c 'declare -A m 2>/dev/null && m[alpha]=1 && m[beta]=2 && [ "${#m[@]}" = 2 ]'; then
  echo "associative-array: interpreter supports declare -A — this is not Bash 3.2" >&2
  exit 1
fi

# The collapse itself, demonstrated rather than asserted from the version number: two
# distinct string keys must NOT yield two elements on this interpreter.
count=$("$BASH" -c 'm[alpha]=1; m[beta]=2; printf "%s" "${#m[@]}"' 2>/dev/null || printf 'error')
if [ "$count" != "1" ]; then
  echo "associative-array: expected string-keyed assignment to collapse to one indexed slot, got '$count'" >&2
  exit 1
fi

echo "associative-array: declare -A is rejected and string keys collapse to one slot, as Bash 3.2 requires"
exit 0
