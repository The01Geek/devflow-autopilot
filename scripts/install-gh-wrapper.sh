#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# install-gh-wrapper.sh — the single checked-in gh-fresh wrapper installer that
# both writer workflows (devflow-implement.yml's claude job, devflow.yml's
# command job) invoke, replacing two byte-identical inline YAML step bodies
# (issue #533).
#
# What it installs: copies scripts/gh-fresh.sh into a wrapper directory as
# `gh`, records the job-start token's sha256 fingerprint (mode 0600) for the
# wrapper's ambient-vs-chosen discrimination (issue #487), publishes the real
# gh's absolute path as DEVFLOW_GH_REAL via GITHUB_ENV, and prepends the
# wrapper directory to later steps' PATH via GITHUB_PATH.
#
# It deliberately publishes NO process-global DEVFLOW_GH (issue #533):
# GITHUB_ENV values persist into every later job step, and DevFlow's resolvers
# treat a non-empty DEVFLOW_GH as the strongest explicit override — so a
# workflow-level export leaks into the repository test process, where it
# outranks the PATH stubs the suite's fixtures install. Wrapper selection is
# PATH-scoped; DEVFLOW_GH stays an explicit caller/test injection seam.
#
# The fingerprint is computed with the preflight-guaranteed python3 hashlib —
# never sha256sum/shasum/awk, which the runner PATH does not guarantee and
# whose silent absence would ship an empty fingerprint (the CLAUDE.md
# guard-class-2 rule: a value that decides an emitted result must not be
# derived through a non-preflight PATH tool). The token is read from the
# APP_TOKEN environment value and piped via stdin; it never appears on an argv.
#
# Fail-closed contract: exactly seven setup outputs are validated in order,
# and the FIRST failure exits 1 with a diagnostic naming that output
# ("install-gh-wrapper: output N/7 FAILED: ... (slug)"), so the job stops
# before the agent ever runs against a half-installed wrapper. An output may
# carry more than one failure slug — output 5 distinguishes
# fingerprint-compute / fingerprint-nonempty / fingerprint-mode — and
# lib/test/run.sh pins the slugs literally (the AC22 umask mutation proof
# depends on fingerprint-mode specifically), so do not "normalize" them.
#
# Env contract:
#   APP_TOKEN                    required — the minted App token to fingerprint
#   GITHUB_ENV / GITHUB_PATH     required — the Actions environment files
#   RUNNER_TEMP                  required unless both path overrides are given
#   DEVFLOW_GH_WRAPDIR           override; default $RUNNER_TEMP/devflow-gh-bin
#   DEVFLOW_GH_FINGERPRINT_FILE  override; default $RUNNER_TEMP/devflow-gh-fingerprint
#                                (the same default gh-fresh.sh reads — a coupled
#                                default pinned by lib/test/run.sh)
#   DEVFLOW_GH_SOURCE_SH         override for the gh-fresh.sh source path

set -uo pipefail

fail() { printf 'install-gh-wrapper: %s\n' "$1" >&2; exit 1; }

# output 1/7 — an executable real gh, resolved BEFORE the wrapper dir reaches
# PATH (a name-based lookup after the prepend would recurse into the wrapper).
# Deliberately a bare `command -v gh`, NOT the lib/resolve-gh.sh resolver: the
# resolver's DEVFLOW_GH override outranks PATH by design, and honoring it here
# could capture the very wrapper this script installs (or any test override) as
# "the real gh" — the recursion this absolute capture exists to prevent. Tests
# steer this lookup with a PATH stub, the same seam production uses.
REAL_GH="$(command -v gh 2>/dev/null || true)"
# The [ -x ] half is defense-in-depth with no drivable test seam: bash's PATH
# search returns only executable regular files (a non-executable file or a
# directory named gh is skipped, rc 1 — verified empirically), so this arm can
# fire only on a permission flip between resolution and test.
[ -n "$REAL_GH" ] && [ -x "$REAL_GH" ] \
  || fail "output 1/7 FAILED: no executable real gh resolved (real-gh-resolve)"

# output 2/7 — a readable wrapper source. Vendored-or-repo fallback: a consumer
# checkout carries only the vendored copy; the source repo carries scripts/.
SRC="${DEVFLOW_GH_SOURCE_SH:-}"
if [ -z "$SRC" ]; then
  if [ -f .devflow/vendor/devflow/scripts/gh-fresh.sh ]; then SRC=.devflow/vendor/devflow/scripts/gh-fresh.sh
  elif [ -f scripts/gh-fresh.sh ]; then SRC=scripts/gh-fresh.sh
  fi
fi
[ -n "$SRC" ] && [ -r "$SRC" ] \
  || fail "output 2/7 FAILED: wrapper source gh-fresh.sh is not readable at the vendored or repo-relative path (wrapper-source-read)"

# output 3/7 — a creatable, writable wrapper directory.
if [ -z "${DEVFLOW_GH_WRAPDIR:-}" ] && [ -z "${RUNNER_TEMP:-}" ]; then
  fail "output 3/7 FAILED: RUNNER_TEMP is unset and no DEVFLOW_GH_WRAPDIR override was given (wrapdir-create)"
fi
WRAPDIR="${DEVFLOW_GH_WRAPDIR:-$RUNNER_TEMP/devflow-gh-bin}"
mkdir -p "$WRAPDIR" && [ -d "$WRAPDIR" ] && [ -w "$WRAPDIR" ] \
  || fail "output 3/7 FAILED: wrapper dir $WRAPDIR could not be created or is not writable (wrapdir-create)"

# output 4/7 — a successful copy carrying the executable bit. The regular-file
# check matters: `cp` into a directory that happens to occupy $WRAPDIR/gh would
# "succeed" while leaving no wrapper at the path later steps invoke.
cp "$SRC" "$WRAPDIR/gh" && chmod +x "$WRAPDIR/gh" \
  && [ -f "$WRAPDIR/gh" ] && [ -x "$WRAPDIR/gh" ] \
  || fail "output 4/7 FAILED: copying $SRC to $WRAPDIR/gh (or chmod +x) did not produce an executable wrapper file (wrapper-copy-exec)"

# output 5/7 — a non-empty, mode-0600 job-start token fingerprint, hashed with
# the preflight-guaranteed python3 hashlib (token via stdin, never argv).
[ -n "${APP_TOKEN:-}" ] \
  || fail "output 5/7 FAILED: APP_TOKEN is empty or unset — no token to fingerprint (fingerprint-compute)"
if [ -z "${DEVFLOW_GH_FINGERPRINT_FILE:-}" ] && [ -z "${RUNNER_TEMP:-}" ]; then
  fail "output 5/7 FAILED: RUNNER_TEMP is unset and no DEVFLOW_GH_FINGERPRINT_FILE override was given (fingerprint-compute)"
fi
FINGERPRINT_FILE="${DEVFLOW_GH_FINGERPRINT_FILE:-$RUNNER_TEMP/devflow-gh-fingerprint}"
( umask 077
  printf '%s' "$APP_TOKEN" \
    | python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' \
    > "$FINGERPRINT_FILE"
) \
  || fail "output 5/7 FAILED: the python3 hashlib fingerprint computation errored (fingerprint-compute)"
[ -s "$FINGERPRINT_FILE" ] \
  || fail "output 5/7 FAILED: fingerprint file $FINGERPRINT_FILE is empty after the write (fingerprint-nonempty)"
# Mode check via python3 too (stat's -c/-f flags diverge GNU/BSD and stat is not
# preflight-guaranteed); an unreadable mode fails CLOSED with the same slug.
_fpmode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$FINGERPRINT_FILE" 2>/dev/null || true)"
[ "$_fpmode" = "600" ] \
  || fail "output 5/7 FAILED: fingerprint file $FINGERPRINT_FILE is mode ${_fpmode:-unreadable}, not 0600 (fingerprint-mode)"

# output 6/7 — a writable GITHUB_ENV, receiving ONLY the real gh's absolute
# path. The wrapper resolves the real CLI through this seam; no DEVFLOW_GH is
# published (see the header).
{ [ -n "${GITHUB_ENV:-}" ] && echo "DEVFLOW_GH_REAL=$REAL_GH" >> "$GITHUB_ENV"; } \
  || fail "output 6/7 FAILED: GITHUB_ENV is unset or not appendable (github-env-write)"

# output 7/7 — a writable GITHUB_PATH, prepending the wrapper dir for later steps.
{ [ -n "${GITHUB_PATH:-}" ] && echo "$WRAPDIR" >> "$GITHUB_PATH"; } \
  || fail "output 7/7 FAILED: GITHUB_PATH is unset or not appendable (github-path-write)"

printf 'install-gh-wrapper: installed (wrapdir=%s real_gh=%s)\n' "$WRAPDIR" "$REAL_GH"
