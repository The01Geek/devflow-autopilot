#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Assert that an observed `claude --version` string carries an EXACT expected version.
#
# Extracted from `.github/workflows/ci.yml`'s verify step so the suite can drive each
# arm. CLAUDE.md's convention: inline workflow shell that selects a branch or composes a
# user-facing message is extracted into a `scripts/*.sh` helper, because a grep-pin on a
# message literal is not coverage of the selection that chooses it — left inline, the
# whole step could be deleted and the suite would stay green.
#
# Usage: assert-cli-version.sh <expected-version> <version-output>
#
# Exit codes are the contract the suite drives:
#   0 — the observed version field equals <expected-version>
#   2 — <expected-version> is empty (the pin would be vacuous; fail CLOSED, never accept)
#   1 — the observed version field differs from <expected-version>
#
# The empty-pin arm is its own exit code rather than folded into the mismatch arm: an
# empty pin is a broken *workflow configuration* (a dropped or renamed `env:` key),
# not a wrong CLI on PATH, and the two want different remedies.
set -u

expected="${1-}"
actual="${2-}"

if [ -z "$expected" ]; then
  echo "::error::CLAUDE_CLI_VERSION is unset or empty; the version pin would be vacuous" >&2
  exit 2
fi

# Compare the version FIELD exactly, not as a substring. An unanchored
# `*"$expected"*` match accepts 2.1.2120 for a 2.1.212 pin; `claude --version`
# prints the version as its first whitespace-delimited field ("2.1.212 (Claude Code)"),
# so trimming at the first space yields the field to compare.
got="${actual%% *}"

if [ "$got" != "$expected" ]; then
  echo "::error::expected claude $expected on PATH, got: $actual" >&2
  exit 1
fi

exit 0
