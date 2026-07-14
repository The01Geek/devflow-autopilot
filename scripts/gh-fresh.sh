#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# gh-fresh.sh — a `gh` wrapper that resolves the token at CALL time from the
# refresher-maintained token file, so agent-side `gh` invocations in a
# >60-minute writer-job run never ride the expiring job-start token (issue #487).
#
# It is wired two ways by the workflow's install step: as `DEVFLOW_GH` in the
# claude step's env (so DevFlow's own gh-callers, which resolve gh through
# lib/resolve-gh.sh's DEVFLOW_GH seam, pick it up) AND ahead of the real `gh` on
# PATH via GITHUB_PATH (so direct skill-fence `gh` calls resolve to it too, and
# every post-claude step inherits it).
#
# Ambient-vs-chosen discrimination (AC "Ambient-vs-chosen credential
# discrimination"): claude-code-action exports the job-start token as BOTH
# GITHUB_TOKEN and GH_TOKEN into its process env, inherited by every agent
# subprocess. A "defer to any preset GH_TOKEN" rule would therefore leave every
# agent call on the expiring ambient token. So the wrapper discriminates by
# FINGERPRINT: the install step records a sha256 of the job-start token, and at
# call time the wrapper
#   * SUBSTITUTES the token-file credential when env GH_TOKEN is absent, OR when
#     its hash matches the recorded job-start fingerprint (the ambient
#     agent-session case — and devflow.yml's #356 flip step, whose GH_TOKEN is
#     that same job-start mint), and
#   * DEFERS untouched when env GH_TOKEN's hash DIFFERS from the fingerprint (a
#     deliberately fresh mint: the #287 stall/review backstops).
# It DEGRADES to a plain invocation — with a stderr breadcrumb, never silently —
# when the substitute decision was taken but the token file is absent/empty, and on
# a bad-credential failure (whichever path) appends one distinctive diagnostic line
# to stderr naming the expired-credential cause — a compaction-immune signal the
# fail-fast rule keys on — while preserving the real gh exit code.
#
# The real gh is invoked by an ABSOLUTE path captured at install time (env
# DEVFLOW_GH_REAL) — a name-based lookup would recurse into this wrapper, which
# the install step prepends to PATH.

set -uo pipefail

TOKEN_FILE="${DEVFLOW_GH_TOKEN_FILE:-${RUNNER_TEMP:-/tmp}/devflow-gh-token}"
FINGERPRINT_FILE="${DEVFLOW_GH_FINGERPRINT_FILE:-${RUNNER_TEMP:-/tmp}/devflow-gh-fingerprint}"
REAL_GH="${DEVFLOW_GH_REAL:-}"

# The distinctive, re-derivable diagnostic the fail-fast prose rule greps for.
DIAG_LINE="devflow-gh-fresh: gh call failed with an expired/bad credential (HTTP 401 / Bad credentials) — the GitHub App installation token has likely expired; stop retrying (issue #487)."

# Resolve the real gh. It MUST be an absolute path so we never recurse into this
# wrapper (which is ahead of gh on PATH). If DEVFLOW_GH_REAL is unset, fall back
# to a best-effort search that excludes ourselves; if that fails, we cannot run.
resolve_real_gh() {
  if [ -n "$REAL_GH" ] && [ -x "$REAL_GH" ]; then printf '%s' "$REAL_GH"; return 0; fi
  local self cand
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # Walk PATH for a `gh` that is not this wrapper.
  local IFS=:
  for d in $PATH; do
    cand="$d/gh"
    if [ -x "$cand" ] && [ "$cand" != "$self" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

sha256_of() {
  # macOS has shasum; ubuntu-hosted runners have sha256sum. Prefer sha256sum.
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# Decide whether to substitute the token-file credential or defer to the ambient
# env GH_TOKEN. Returns 0 to SUBSTITUTE, 1 to DEFER.
decide() {
  # ambient agent session: no explicit token → use the fresh one.
  [ -z "${GH_TOKEN:-}" ] && return 0
  # env GH_TOKEN is present: compare its hash to the recorded job-start fingerprint.
  # A match is the ambient job-start token → substitute; a mismatch is a deliberately
  # fresh mint (#287/#356) → defer untouched.
  local fp cur
  fp="$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)"
  cur="$(sha256_of "$GH_TOKEN" 2>/dev/null || true)"
  # Could-not-establish the comparison (fingerprint file unreadable, or no
  # sha256sum/shasum/awk to hash with) must NOT collapse silently onto the defer
  # path — a buried defer would ride the possibly-expired ambient token, the exact
  # failure this wrapper prevents. Fail toward NOT clobbering a deliberately-fresh
  # #287/#356 backstop mint (defer), but emit a breadcrumb so the state is visible;
  # the two-strikes fail-fast rule then catches a genuinely-expired token.
  if [ -z "$fp" ] || [ -z "$cur" ]; then
    printf 'devflow-gh-fresh: could not establish the job-start fingerprint comparison (fingerprint file unreadable or no sha256 tool on PATH); deferring to the ambient GH_TOKEN — if that is the expired job-start token, gh will 401 and the fail-fast rule applies.\n' >&2
    return 1
  fi
  [ "$cur" = "$fp" ]
}

main() {
  local real
  real="$(resolve_real_gh)" || {
    printf 'devflow-gh-fresh: could not resolve the real gh binary (set DEVFLOW_GH_REAL)\n' >&2
    return 127
  }

  local token=""
  if decide; then
    if [ -f "$TOKEN_FILE" ]; then
      token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
    fi
    # The SUBSTITUTE decision was taken but the refresher-maintained token file is
    # absent, unreadable, or empty (e.g. the refresher was defeated at startup and
    # never wrote it). Degrading to the plain invocation is right, but never
    # silently — every call from here rides the ambient (possibly expiring
    # job-start) token, the exact state this wrapper exists to prevent. Mirrors
    # decide()'s could-not-establish breadcrumb.
    if [ -z "$token" ]; then
      printf 'devflow-gh-fresh: token file %s is absent or empty (was the refresher defeated at startup?); degrading to the plain invocation on the ambient token — if that is the expired job-start token, gh will 401 and the fail-fast rule applies.\n' "$TOKEN_FILE" >&2
    fi
  fi

  # Run the real gh, capturing stderr (to scan for the bad-credential signature)
  # while passing stdout straight through. fd 3 carries the child's stdout to our
  # real stdout; the command substitution captures only stderr.
  local err rc
  exec 3>&1
  if [ -n "$token" ]; then
    err="$( { GH_TOKEN="$token" "$real" "$@"; } 2>&1 1>&3 )"; rc=$?
  else
    # defer path, or substitute-but-token-file-absent degrade path: plain invocation.
    err="$( { "$real" "$@"; } 2>&1 1>&3 )"; rc=$?
  fi
  exec 3>&-

  # Re-emit the captured stderr verbatim.
  [ -n "$err" ] && printf '%s\n' "$err" >&2

  # On a bad-credential failure, append the distinctive diagnostic (both paths).
  if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qiE 'HTTP 401|Bad credentials|Authentication failed'; then
    printf '%s\n' "$DIAG_LINE" >&2
  fi
  return "$rc"
}

main "$@"
