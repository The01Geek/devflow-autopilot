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
# Mirrors the guard's own _store_names()/_run_key() naming for the shapes that matter
# in practice (shadow-review finding, issue #908 review: an earlier revision of this
# comment claimed an exact mirror, which is false for one corner case the note below
# names):
#   - GITHUB_RUN_ID set, GITHUB_RUN_ATTEMPT set  -> pretooluse-guard-counts-<id>-<attempt>.json
#   - GITHUB_RUN_ID set, GITHUB_RUN_ATTEMPT empty -> pretooluse-guard-counts-<id>.json
#   - GITHUB_RUN_ID empty (local/interactive tier) -> pretooluse-guard-counts.json (bare)
#
# CANDIDATE ORDER — the BARE name is always tried, even when a run id was supplied
# (issue #908 confirmatory review, corroborated Critical, reproduced by execution).
# The guard runs as a HOOK SUBPROCESS of claude-code-action, not as the workflow step;
# nothing establishes that GITHUB_RUN_ID is exported into that process. So the guard's
# _run_key() can return None — making it write the BARE store — while THIS script,
# reading the workflow step's own environment, definitely has a run id and builds a
# run-keyed candidate. The glob fallback below cannot rescue that case: its pattern
# `pretooluse-guard-counts-*.json` requires the trailing hyphen and therefore does NOT
# match the bare `pretooluse-guard-counts.json`. Before the bare candidate was added
# here, that combination resolved to "no match", which devflow-runner.yml's consuming
# step turned into a positively-asserted `{}` ("guard fired, zero denials recorded")
# over a store holding real denials — the exact unknown-is-not-zero collapse this
# file's own doctrine forbids, inverted. Order is most-specific-first, so a run-keyed
# store still wins over a bare one when both exist.
#
# ZERO-BYTE IS UNESTABLISHED, NOT ABSENT (exit 2). The guard creates the counts store
# only from `_bump_counts`, i.e. only on a deny decision, so a zero-length store is
# evidence of a PARTIAL/INTERRUPTED write of a non-empty deny record — never of "the
# guard denied nothing". Reporting it as absent would let the consumer's known-zero
# arm assert a confident zero over a known-broken measurement. A candidate (or glob
# match) that exists but is empty therefore exits 2, which the consumer maps to
# `unavailable` plus a warning naming the path.
#
# Known divergence (now genuinely inert — the BARE candidate above closes it, not the
# glob): the guard's _run_key() JOINS then sanitizes (raw = f"{run_id}-{attempt}" when
# attempt is truthy, even with an EMPTY run_id — e.g. run_id="", attempt="1" ->
# raw="-1" -> store name "pretooluse-guard-counts--1.json"), while this script
# sanitizes each part SEPARATELY then joins — so that same input resolves here to the
# BARE candidate name instead. GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT come from the same
# Actions environment, so an empty-id/non-empty-attempt pairing is not a real
# production shape; when it is passed explicitly anyway, the glob fallback still finds
# the guard's actual store (its name matches the glob pattern).
#
# Second known divergence (sanitizing alphabet): the guard's _run_key() filters with
# Python's `str.isalnum()`, which is UNICODE-aware and so KEEPS non-ASCII letters,
# while this script's bash pattern-substitution `${1//[^A-Za-z0-9._-]/}` strips them.
# A run id carrying non-ASCII characters therefore yields different names on the two
# sides. GitHub run ids are decimal digits, so this is not a production shape; when it
# is forced anyway, the glob fallback still matches the guard's run-keyed store.
#
# Usage: resolve-guard-counts-file.sh <TMP_DIR> [GITHUB_RUN_ID] [GITHUB_RUN_ATTEMPT]
#   TMP_DIR             directory to search (the repo's .prflow/tmp — passed
#                        explicitly, never assumed, so this is testable against a
#                        fixture directory).
#   GITHUB_RUN_ID        optional; when omitted, read from the environment.
#   GITHUB_RUN_ATTEMPT   optional; when omitted, read from the environment.
#
# On a match: prints the resolved path (TMP_DIR/<name>) to stdout, exits 0.
# On no match: prints nothing, exits 1.
# On a candidate/glob match that exists but is EMPTY (zero-byte): prints nothing,
#   exits 2 — an unestablished measurement, never "absent" (see the zero-byte note
#   above). A non-empty match anywhere in the order always wins over an empty one.
# Never aborts on a missing/unreadable TMP_DIR (a `[ -d ]` guard treats it as "no
# match" rather than a shell error).

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

# Candidate order, most-specific first. The BARE name is ALWAYS a candidate — see the
# CANDIDATE ORDER note in the header: the guard writes it whenever its own process has
# no run id, a case the run-keyed name and the glob both structurally miss.
set --
if [ -n "$RUN_ID_SAFE" ]; then
  if [ -n "$ATTEMPT_SAFE" ]; then
    set -- "$@" "pretooluse-guard-counts-${RUN_ID_SAFE}-${ATTEMPT_SAFE}.json"
  else
    set -- "$@" "pretooluse-guard-counts-${RUN_ID_SAFE}.json"
  fi
fi
set -- "$@" "pretooluse-guard-counts.json"

# A zero-byte match is recorded, not returned: a later candidate (or the glob) may
# still hold a usable store, and a non-empty match must always win over an empty one.
# Only if the whole order yields nothing usable does the recorded emptiness decide
# between exit 2 (unestablished) and exit 1 (genuinely absent).
SAW_EMPTY=0
for _name in "$@"; do
  if [ -f "$TMP_DIR/$_name" ]; then
    if [ -s "$TMP_DIR/$_name" ]; then
      printf '%s\n' "$TMP_DIR/$_name"
      exit 0
    fi
    SAW_EMPTY=1
  fi
done

# Glob fallback — a run-keyed miss (guard-side derivation drift) still finds SOME
# counts store rather than going silent. Sorted for determinism; first match wins.
# NOTE: this pattern requires the trailing hyphen, so it can never match the bare
# name — which is exactly why the bare name is an explicit candidate above.
for _f in "$TMP_DIR"/pretooluse-guard-counts-*.json; do
  if [ -f "$_f" ]; then
    if [ -s "$_f" ]; then
      printf '%s\n' "$_f"
      exit 0
    fi
    SAW_EMPTY=1
  fi
done

[ "$SAW_EMPTY" -eq 0 ] || exit 2
exit 1
