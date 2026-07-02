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
# Share the generic execution-verified binary-selection contract (see
# lib/resolve-bin.sh) — jq resolves through it here, and resolve-gh.sh
# delegates to it for gh. Guarded (family partial-copy posture): a deployment
# missing the sibling degrades to bare-name resolution with a breadcrumb, so
# the jq/gh diagnoses below stay attributable instead of blaming a phantom
# Windows shim ("the resolved '' does not execute").
# shellcheck source=resolve-bin.sh
if [ -f "$_PREFLIGHT_DIR/resolve-bin.sh" ] \
   && . "$_PREFLIGHT_DIR/resolve-bin.sh" \
   && type devflow_resolve_bin >/dev/null 2>&1; then
  :
else
  printf 'devflow preflight: lib/resolve-bin.sh missing or not sourceable beside preflight.sh (partial copy?) — tool resolution degraded to override-or-bare-name\n' >&2
  # Degrade override-FIRST (the family posture): preflight DETECTs with the
  # same value the helpers USE, so a set DEVFLOW_JQ/DEVFLOW_GH is still what
  # gets probed here even in the degraded mode.
  devflow_resolve_bin() {
    case "${1:-}" in
      jq) printf '%s\n' "${DEVFLOW_JQ:-jq}" ;;
      gh) printf '%s\n' "${DEVFLOW_GH:-gh}" ;;
      *)  printf '%s\n' "${1:-}" ;;
    esac
  }
fi
# Share the gh-selection contract with every gh-calling helper (see lib/resolve-gh.sh)
# so preflight DETECTS with the same execution-verified probe the helpers USE.
# Guarded like resolve-bin.sh above (same partial-copy posture, same
# override-first degradation).
# shellcheck source=resolve-gh.sh
if [ -f "$_PREFLIGHT_DIR/resolve-gh.sh" ] \
   && . "$_PREFLIGHT_DIR/resolve-gh.sh" \
   && type devflow_resolve_gh >/dev/null 2>&1; then
  :
else
  printf 'devflow preflight: lib/resolve-gh.sh missing or not sourceable beside preflight.sh (partial copy?) — gh resolution degraded to DEVFLOW_GH-or-bare-gh\n' >&2
  devflow_resolve_gh() { printf '%s\n' "${DEVFLOW_GH:-gh}"; }
fi

missing=0

_need() {  # $1=command  $2=how-to-install hint
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'devflow preflight: missing required tool %s — %s\n' "'$1'" "$2" >&2
    missing=1
  fi
}

_need git     "install git"

# jq resolution — mirror the gh two-branch diagnosis below: execution-verified
# via the shared resolver, not a bare presence check. On a stock Windows/WSL
# host a non-executable `jq` shim can shadow the real jq: `command -v jq`
# succeeds but the binary cannot run, so a plain presence check would pass
# preflight while every jq-calling helper breaks. devflow_resolve_bin probes
# candidates with a network/auth-free `jq --version` and returns the first
# runnable one (or bare `jq` when none runs); we re-probe the chosen invocation
# here so an unrunnable jq is reported with a remedy instead of silently
# passing.
_JQ="$(devflow_resolve_bin jq)"
if ! "$_JQ" --version >/dev/null 2>&1; then
  # Two accurate diagnoses instead of one hedged one: when jq is simply not
  # installed (nothing named jq/jq.exe on PATH and no override), say so
  # plainly; the shim wording applies only when something IS present but does
  # not run. Both branches keep the literal "no working 'jq'".
  if [ -z "${DEVFLOW_JQ:-}" ] && ! command -v jq >/dev/null 2>&1 && ! command -v jq.exe >/dev/null 2>&1; then
    printf "devflow preflight: no working 'jq' — jq is not installed (nothing named jq/jq.exe on PATH). Install it (https://jqlang.github.io/jq/) or set DEVFLOW_JQ to a working jq/jq.exe.\n" >&2
  else
    printf "devflow preflight: no working 'jq' on PATH (the resolved '%s' does not execute — e.g. a non-executable shim shadowing the real jq on Windows/WSL). Install jq (https://jqlang.github.io/jq/), or set DEVFLOW_JQ to a working jq/jq.exe.\n" "$_JQ" >&2
  fi
  missing=1
fi

# gh resolution — mirror the resolve-python.sh sibling's detect-and-verify path:
# use the execution-verified single-source resolver, not a bare presence check. On a stock Windows/WSL host a
# non-executable `gh` shim (a Python-provided `gh` with a Windows shebang) can
# shadow the real GitHub CLI: `command -v gh` succeeds but the binary cannot run,
# so a plain presence check would pass preflight while every gh-calling helper
# breaks. devflow_resolve_gh probes candidates with a network/auth-free
# `gh --version` and returns the first runnable one (or bare `gh` when none runs);
# we re-probe the chosen invocation here so an unrunnable gh is reported with a
# remedy instead of silently passing.
_GH="$(devflow_resolve_gh)"
if ! "$_GH" --version >/dev/null 2>&1; then
  # Two accurate diagnoses instead of one hedged one: when gh is simply not
  # installed (nothing named gh/gh.exe on PATH and no override), say so plainly;
  # the shim wording applies only when something IS present but does not run.
  # Both branches keep the literal "no working 'gh'" (the AC5 test pins it).
  if [ -z "${DEVFLOW_GH:-}" ] && ! command -v gh >/dev/null 2>&1 && ! command -v gh.exe >/dev/null 2>&1; then
    printf "devflow preflight: no working 'gh' — the GitHub CLI is not installed (nothing named gh/gh.exe on PATH). Install it (https://cli.github.com) and run 'gh auth login'.\n" >&2
  else
    printf "devflow preflight: no working 'gh' on PATH (the resolved '%s' does not execute — e.g. a non-executable shim shadowing the real GitHub CLI on Windows/WSL). Install the GitHub CLI (https://cli.github.com) and run 'gh auth login', or set DEVFLOW_GH to a working gh/gh.exe.\n" "$_GH" >&2
  fi
  missing=1
fi

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
