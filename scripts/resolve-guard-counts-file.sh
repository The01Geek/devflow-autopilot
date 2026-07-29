#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-guard-counts-file.sh — resolve the on-disk path of
# scripts/pretooluse-shape-guard.py's per-arm counts store (issue #908). Extracted
# from devflow-runner.yml's inline shell per CLAUDE.md's inline-shell-extraction
# convention (scripts/describe-denial-count.sh is the reference precedent): this
# logic SELECTS which file to read (run-keyed name, then the bare legacy name, then a
# glob fallback), so it must be suite-drivable rather than left as untested workflow
# YAML — the same "a value that decides a SELECTION must be testable" concern
# CLAUDE.md's guard-class 2 raises for the selection itself.
#
# Mirrors the guard's own _store_names()/_run_key() naming exactly:
#   - GITHUB_RUN_ID set, GITHUB_RUN_ATTEMPT set  -> pretooluse-guard-counts-<id>-<attempt>.json
#   - GITHUB_RUN_ID set, GITHUB_RUN_ATTEMPT empty -> pretooluse-guard-counts-<id>.json
#   - GITHUB_RUN_ID empty (local/interactive tier) -> pretooluse-guard-counts.json (bare)
# When the run-keyed (or bare) name does not exist, falls back to a glob match on
# `pretooluse-guard-counts-*.json` (covers a guard-side run-key derivation drift
# without going silent) before giving up.
#
# Usage: resolve-guard-counts-file.sh <TMP_DIR> [GITHUB_RUN_ID] [GITHUB_RUN_ATTEMPT]
#   TMP_DIR             directory to search (the repo's .devflow/tmp — passed
#                        explicitly, never assumed, so this is testable against a
#                        fixture directory).
#   GITHUB_RUN_ID        optional; when omitted, read from the environment.
#   GITHUB_RUN_ATTEMPT   optional; when omitted, read from the environment.
#
# On a match: prints the resolved path (TMP_DIR/<name>) to stdout, exits 0.
# On no match: prints nothing, exits 1. Never aborts on a missing/unreadable TMP_DIR
# (a `[ -d ]` guard treats it as "no match" rather than a shell error).

set -u

TMP_DIR="${1:-}"
RUN_ID="${2-${GITHUB_RUN_ID:-}}"
ATTEMPT="${3-${GITHUB_RUN_ATTEMPT:-}}"

if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
  exit 1
fi

# Sanitize to the same filename-safe alphabet the guard's _run_key() uses (alnum,
# `.`, `_`, `-`) via a bash builtin pattern-substitution — never a PATH tool for a
# value that decides which file gets read.
_sanitize() { printf '%s' "${1//[^A-Za-z0-9._-]/}"; }

RUN_ID_SAFE=$(_sanitize "$RUN_ID")
ATTEMPT_SAFE=$(_sanitize "$ATTEMPT")

CANDIDATE=""
if [ -n "$RUN_ID_SAFE" ]; then
  if [ -n "$ATTEMPT_SAFE" ]; then
    CANDIDATE="pretooluse-guard-counts-${RUN_ID_SAFE}-${ATTEMPT_SAFE}.json"
  else
    CANDIDATE="pretooluse-guard-counts-${RUN_ID_SAFE}.json"
  fi
else
  CANDIDATE="pretooluse-guard-counts.json"
fi

if [ -f "$TMP_DIR/$CANDIDATE" ] && [ -s "$TMP_DIR/$CANDIDATE" ]; then
  printf '%s\n' "$TMP_DIR/$CANDIDATE"
  exit 0
fi

# Glob fallback — a run-keyed miss (guard-side derivation drift) still finds SOME
# counts store rather than going silent. Sorted for determinism; first match wins.
for _f in "$TMP_DIR"/pretooluse-guard-counts-*.json; do
  if [ -f "$_f" ] && [ -s "$_f" ]; then
    printf '%s\n' "$_f"
    exit 0
  fi
done

exit 1
