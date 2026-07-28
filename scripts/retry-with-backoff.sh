#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Run a command with bounded retries and exponential backoff.
#
# Extracted from `.github/workflows/ci.yml`'s CLI-install step so the suite can drive
# its arms. CLAUDE.md's convention: inline workflow shell that selects a branch or
# composes a user-facing message belongs in a `scripts/*.sh` helper — left inline,
# nothing drives the retry arms, the backoff schedule, or the terminal exit.
#
# Usage: retry-with-backoff.sh <attempts> <base-delay-seconds> <command-string>
#
# The command string is run with `bash -c`, so the caller owns its own pipefail and
# quoting. Exit codes:
#   0 — the command succeeded on some attempt
#   1 — every attempt failed (an ::error:: naming the attempt count is emitted)
#   2 — the arguments themselves are unusable (fail closed; never retry nothing)
#
# The success flag is explicit rather than a comparison against the last attempt
# number. A hand-transcribed terminal literal (`[ "$attempt" = 3 ]`) is coupled to the
# loop bound: widening the bound silently stops the terminal arm from ever firing, and
# the caller then proceeds as though the command had succeeded.
set -u

attempts="${1-}"
base_delay="${2-}"
command_string="${3-}"

case "$attempts" in
  ''|*[!0-9]*) echo "retry-with-backoff: attempts must be a non-negative integer, got: '${attempts}'" >&2; exit 2 ;;
esac
case "$base_delay" in
  ''|*[!0-9]*) echo "retry-with-backoff: base delay must be a non-negative integer, got: '${base_delay}'" >&2; exit 2 ;;
esac
if [ "$attempts" -lt 1 ]; then
  echo "retry-with-backoff: attempts must be at least 1, got: '${attempts}'" >&2; exit 2
fi
if [ -z "$command_string" ]; then
  echo "retry-with-backoff: no command given" >&2; exit 2
fi

succeeded=
delay="$base_delay"
attempt=1
while [ "$attempt" -le "$attempts" ]; do
  if bash -c "$command_string"; then
    succeeded=yes
    break
  fi
  if [ "$attempt" -lt "$attempts" ]; then
    echo "retry-with-backoff: attempt ${attempt} of ${attempts} failed; retrying in ${delay}s" >&2
    [ "$delay" -gt 0 ] && sleep "$delay"
    delay=$((delay * 3))
  fi
  attempt=$((attempt + 1))
done

if [ -z "$succeeded" ]; then
  echo "::error::command failed after ${attempts} attempt(s): ${command_string}" >&2
  exit 1
fi
exit 0
