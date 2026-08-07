#!/bin/bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Assert the running interpreter is stock Bash 3.2 — exactly.
#
# Every other fixture in this corpus is a claim ABOUT Bash 3.2, so a corpus that ran
# green under Bash 5 would report a portable surface it never exercised. This fixture
# is what makes the rest of the lane mean anything, and it is deliberately an equality
# on BOTH version components: the interpreter this lane exists for is the stock macOS
# one, 3.2.57, so "major is 3" is not the property the lane claims to verify — and Bash 4
# supports the very constructs the corpus asserts are absent.
#
# Exit 0 = the interpreter is 3.2. Exit 1 = anything else, naming what it actually is.
set -u

if [ -z "${BASH_VERSINFO+set}" ]; then
  echo "interpreter-version: BASH_VERSINFO is unset — this is not bash" >&2
  exit 1
fi

major="${BASH_VERSINFO[0]}"
minor="${BASH_VERSINFO[1]}"

if [ "$major" != "3" ] || [ "$minor" != "2" ]; then
  echo "interpreter-version: expected stock Bash 3.2, got ${major}.${minor} (${BASH_VERSION:-unknown})" >&2
  exit 1
fi

echo "interpreter-version: Bash ${BASH_VERSION}"
exit 0
