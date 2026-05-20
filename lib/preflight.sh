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
_need python3 "install Python 3.11 or newer"

if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    printf "devflow preflight: Python package PyYAML not found — run 'python3 -m pip install pyyaml'\n" >&2
    missing=1
  fi
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    printf 'devflow preflight: Python 3.11+ required (found %s)\n' "$(python3 -V 2>&1)" >&2
    missing=1
  fi
fi

if [ "$missing" -ne 0 ]; then
  printf 'devflow preflight: one or more required dependencies are missing (see above).\n' >&2
  exit 1
fi

printf 'devflow preflight: all dependencies present.\n'
