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
# quoting. That `bash -c` inherits the caller's exported environment, so a command
# string single-quoted by the caller has its variables expanded HERE, per attempt.
# Exit codes:
#   0 — the command succeeded on some attempt
#   1 — every attempt failed (an ::error:: naming the attempt count AND the last
#       observed exit code is emitted)
#   2 — the arguments themselves are unusable (fail closed; never retry nothing)
#
# The exhaustion exit is a flat 1 rather than the command's own last exit code: the
# two failure directions a caller must distinguish are "the command never succeeded"
# and "the arguments were unusable", and forwarding an arbitrary command exit would
# collide with the 2 that means the latter. The last observed code is carried in the
# ::error:: message instead, so a deterministic failure (a mistyped version pinning a
# 404) is diagnosable without re-running.
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
  ''|*[!0-9]*) echo "retry-with-backoff: attempts must be an integer, got: '${attempts}'" >&2; exit 2 ;;
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
last_rc=
delay="$base_delay"
attempt=1
while [ "$attempt" -le "$attempts" ]; do
  # Captured on its own line rather than read as `$?` after an `if`: an `if` whose
  # branch does not run reports its own 0, so the command's status has to be taken
  # directly from the command.
  bash -c "$command_string"; last_rc=$?
  if [ "$last_rc" -eq 0 ]; then
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
  echo "::error::command failed after ${attempts} attempt(s) (last exit ${last_rc}): ${command_string}" >&2
  exit 1
fi
exit 0
