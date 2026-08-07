#!/bin/bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# `${v,,}` / `${v^^}` case-modification expansion is Bash 4 only. Under Bash 3.2 it is
# a bad substitution, and a shipped helper that reaches for it silently produces the
# wrong value on macOS rather than failing where a reader would look.
#
# The assertion runs the expansion in a CHILD shell so its bad-substitution error is
# this fixture's observable outcome rather than this fixture's own death: a
# `${v,,}` written directly here would abort the script at parse-adjacent expansion
# time and never reach the comparison.
#
# Exit 0 = the interpreter refuses the expansion (it is 3.2-shaped).
# Exit 1 = the interpreter performed it (a Bash 4+ interpreter — the corpus is running
#          somewhere it cannot verify what it claims to).
set -u

check() {
  # $1 is the expansion under test, passed as source text to a child bash.
  #
  # A non-zero status alone would NOT establish the refusal: 127 (not found) and 126
  # (not executable) are also non-zero, so a $BASH that never ran would read as an
  # interpreter that rejected the expansion — an absence established by a probe that
  # never happened. Those two statuses are therefore called out separately.
  out=$("$BASH" -c "v=MiXeD; printf '%s' \"$1\"" 2>/dev/null)
  status=$?
  case "$status" in
    0)
      echo "case-modification: interpreter performed $1 (produced '$out') — this is not Bash 3.2" >&2
      return 1
      ;;
    126|127)
      echo "case-modification: the probe interpreter '$BASH' could not be run (status $status) — the refusal of $1 was never established" >&2
      return 1
      ;;
  esac
  return 0
}

rc=0
check '${v,,}' || rc=1
check '${v^^}' || rc=1

[ "$rc" -eq 0 ] && echo "case-modification: both case-modification forms are rejected, as Bash 3.2 requires"
exit "$rc"
