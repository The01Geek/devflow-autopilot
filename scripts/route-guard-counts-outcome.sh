#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# route-guard-counts-outcome.sh — select the PreToolUse guard counts-store OUTCOME
# from resolve-guard-counts-file.sh's exit code + the heartbeat's FIRED verdict
# (issue #908 review, Important finding #2: this routing lived only as inline YAML
# in devflow-runner.yml's `guard` step, covered by structural grep pins rather than
# a suite-drivable helper — a regressed arm order or comparison would not fail the
# suite).
#
# "Unknown is not zero" (CLAUDE.md): four RGC_RC/FIRED combinations must NOT
# collapse onto the same outcome —
#   rc=0              a counts-store file was found and should be jq-parsed
#   rc=2               the store exists but is zero-byte -> unavailable, never zero
#   rc=1 and FIRED=true  no store file, but the heartbeat proves the guard ran
#                        this run -> a positively-known zero ({})
#   anything else       our own tooling could not establish a verdict -> unavailable
#
# Usage: route-guard-counts-outcome.sh RGC_RC FIRED
#   RGC_RC  resolve-guard-counts-file.sh's captured exit status (an integer).
#   FIRED   "true" or "false" (or anything else, treated as not-fired).
# Prints two lines to stdout and always exits 0:
#   line 1: one of parse | zero-byte | known-zero | unavailable
#   line 2: a notice/warning message to surface (empty line if none)

set -u

RGC_RC="${1:-}"
FIRED="${2:-}"

case "$RGC_RC" in
  0)
    printf 'parse\n\n'
    ;;
  2)
    printf 'zero-byte\n'
    printf '%s\n' "resolve-guard-counts-file.sh found a zero-byte counts store under .devflow/tmp (partial or interrupted write); per-arm denial counts reported as unavailable rather than as a zero."
    ;;
  1)
    if [ "$FIRED" = true ]; then
      printf 'known-zero\n\n'
    else
      printf 'unavailable\n\n'
    fi
    ;;
  *)
    printf 'unavailable\n'
    printf '%s\n' "resolve-guard-counts-file.sh exited $RGC_RC (present but unrunnable, or an unexpected status); per-arm denial counts reported as unavailable rather than as a zero."
    ;;
esac
exit 0
