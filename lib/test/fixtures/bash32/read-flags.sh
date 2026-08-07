#!/bin/bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# `read` flags, split by which side of the 3.2/4.0 boundary they sit on.
#
# The flags shipped helpers use — `-r`, `-d`, and the `IFS= read -r line` idiom the
# repository's guard-class-2 convention mandates in place of `wc`/`cut` — must work.
# `read -N` (read exactly N characters, ignoring the delimiter) is Bash 4 only and must
# NOT: a helper that reached for it would read a *line* on macOS instead of N bytes,
# which is a wrong value rather than an error.
#
# Exit 0 = the 3.2 flag set works and the 4.0 flag is refused.
# Exit 1 = otherwise, naming which claim failed.
set -u

fail() { echo "read-flags: $1" >&2; exit 1; }

# -r: backslashes stay literal.
got=$(printf 'a\\tb\n' | { IFS= read -r line; printf '%s' "$line"; })
[ "$got" = 'a\tb' ] || fail "IFS= read -r did not preserve the backslash (got '$got')"

# -d: an alternate delimiter, which the NUL-safe helpers depend on.
got=$(printf 'first;second' | { IFS= read -r -d ';' field; printf '%s' "$field"; })
[ "$got" = 'first' ] || fail "read -d ';' did not stop at the delimiter (got '$got')"

# The while-read enumeration idiom this repository mandates for derived values.
count=0
while IFS= read -r _; do count=$((count + 1)); done <<'ROWS'
one
two
three
ROWS
[ "$count" = 3 ] || fail "the while/IFS= read -r enumeration counted $count, expected 3"

# -N is Bash 4 only. Assert the interpreter refuses it rather than silently reading a line.
if printf 'abcdef' | "$BASH" -c 'read -N 3 chunk 2>/dev/null && [ "$chunk" = abc ]'; then
  fail "interpreter supports read -N — this is not Bash 3.2"
fi

echo "read-flags: -r, -d and the while-read idiom work; read -N is refused, as Bash 3.2 requires"
exit 0
