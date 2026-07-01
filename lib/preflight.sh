#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# preflight.sh — verify DevFlow's runtime dependencies are present, with clear,
# actionable errors. Exits 0 when everything is available, 1 otherwise.
#
#   bash "${CLAUDE_SKILL_DIR}/../../lib/preflight.sh"
#
# DevFlow's shell/Python helpers assume: git, gh (authenticated), jq, and
# python3 (>=3.11) with PyYAML. Date math and text extraction were written to
# avoid GNU-only flags (no `date -d`, no `grep -P`), so coreutils/grep flavor
# does not matter — but the four tools above are required.
set -u

# Share the interpreter-selection contract with scripts/provision-python3-shim.sh so the
# two can never disagree on which Python DevFlow uses (see lib/resolve-python.sh).
_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-python.sh
. "$_PREFLIGHT_DIR/resolve-python.sh"

missing=0

_need() {  # $1=command  $2=how-to-install hint
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'devflow preflight: missing required tool %s — %s\n' "'$1'" "$2" >&2
    missing=1
  fi
}

_need git     "install git"
_need gh      "install the GitHub CLI (https://cli.github.com) and run 'gh auth login'"
_need jq      "install jq (https://jqlang.github.io/jq/)"

# Python resolution. `python3` is the preferred command and the normal macOS/Linux path. It
# is taken only when it is both present AND actually runs (`-c 'pass'`) — the same runnability
# probe devflow_resolve_python applies to every alternate — so a present-but-broken `python3`
# (a dangling symlink, a corrupt install, a missing runtime DLL — the broken-Windows-interpreter
# class the shim provisioner targets) does NOT short-circuit here into a misleading "PyYAML not
# found" / wrong-version message with no pointer to the remedy; it falls through to the resolver,
# which skips it and tries `py -3` / `python`. Its >=3.11 version is confirmed by the check below,
# not in this branch — output is unchanged on a real python3 >=3.11. On a stock Windows Python
# install there is no `python3` on PATH — Python is reachable only as `python` / `py -3` —
# so instead of the bare "missing python3" dead end, point the user at the consent-gated
# shim provisioner and run the PyYAML/version checks against whatever interpreter resolves.
# PYTHON holds the invocation the checks below run against ("" when none is usable).
PYTHON=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
  PYTHON="python3"
else
  _resolved=""
  _rc=0
  _resolved="$(devflow_resolve_python)" || _rc=$?
  if [ "$_rc" -eq 0 ]; then
    # A >=3.11 alternate exists but `python3` does not (it is either absent, or present-but-broken
    # and rejected by the runnability probe above — hence "no working python3", not "not on PATH",
    # which would read as contradictory to a user whose `command -v python3` resolves). The
    # toolchain's literal `python3` calls still fail until a shim is in place, so this is still a
    # missing dependency — but an actionable one: direct the user to the provisioner, not a dead end.
    printf "devflow preflight: no working 'python3' on PATH, but a compatible Python (>=3.11) is available as '%s'. Run scripts/provision-python3-shim.sh to install a 'python3' shim so the toolchain resolves it (Windows/Git-Bash); see docs/install.md.\n" "$_resolved" >&2
    PYTHON="$_resolved"
    missing=1
  elif [ "$_rc" -eq 1 ]; then
    # A Python exists but is older than 3.11: give the specific version failure, never the
    # misleading "missing" message. $_resolved is the first runnable (too-old) invocation.
    # "no working python3" (not "no python3 on PATH") because python3 may be present-but-broken
    # and rejected by the runnability probe above, not strictly absent.
    # shellcheck disable=SC2086  # $_resolved may be the two words "py -3"
    printf 'devflow preflight: Python 3.11+ required (no working python3 on PATH; the available Python is older: %s)\n' "$($_resolved -V 2>&1)" >&2
    missing=1
  else
    printf "devflow preflight: missing required tool 'python3' — install Python 3.11 or newer\n" >&2
    missing=1
  fi
fi

if [ -n "$PYTHON" ]; then
  # shellcheck disable=SC2086  # $PYTHON may be the two words "py -3"
  if ! $PYTHON -c 'import yaml' >/dev/null 2>&1; then
    printf "devflow preflight: Python package PyYAML not found — run '%s -m pip install pyyaml'\n" "$PYTHON" >&2
    missing=1
  fi
  # Version check only for the `python3` happy path — that branch above did NOT call
  # devflow_resolve_python, so python3's version is still unverified here. The resolved
  # ALTERNATE path is already version-verified (devflow_resolve_python returns rc 0 only
  # for a >=3.11 invocation), so re-checking it would be a guaranteed-pass, redundant spawn.
  if [ "$PYTHON" = "python3" ] && ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    printf 'devflow preflight: Python 3.11+ required (found %s)\n' "$(python3 -V 2>&1)" >&2
    missing=1
  fi
fi

if [ "$missing" -ne 0 ]; then
  printf 'devflow preflight: one or more required dependencies are missing (see above).\n' >&2
  exit 1
fi

printf 'devflow preflight: all dependencies present.\n'
