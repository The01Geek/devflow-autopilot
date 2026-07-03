#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Read a value from .devflow/config.json — DevFlow's single config resolver.
#
# Usage: config-get.sh KEY [DEFAULT] [CONFIG_FILE]
#   KEY          dot-path like .docs.internal or .devflow.workpad_marker
#                (leading dot optional). Arbitrary nesting depth supported —
#                the path is split on dots and walked through nested objects.
#   DEFAULT      printed if key is absent or value is empty/null. Pass an
#                empty string ("") to explicitly request empty-on-missing.
#   CONFIG_FILE  defaults to .devflow/config.json
#
# SHARED CWD-RELATIVE CONFIG CONTRACT: this resolver and scripts/workpad.py's
# in-process marker read both resolve `.devflow/config.json` relative to the current
# working directory (the repo root in normal use) — NOT via git-root discovery. Keep
# the two in lockstep: a run invoked from a repo subdirectory resolves config the same
# way for both readers, so neither silently disagrees with the other about a
# subdirectory-invoked custom config. (workpad.py cannot exec this .sh on Windows —
# [WinError 193] — so it re-implements the same cwd-relative read in Python; issue #275.)
#
# Parses with python3, which is a hard DevFlow prerequisite (lib/preflight.sh
# requires python3 >= 3.11; the whole scripts/*.py surface depends on it) and so
# is guaranteed on every host where DevFlow runs — including non-Node hosts where
# `node` is absent. Uses only the stdlib `json` module; no PyYAML or yq required
# (config is JSON). This is the ONE config-reading implementation in DevFlow;
# lib/config-source.sh delegates here.
#
# Exit codes:
#   0  value (or default) printed to stdout
#   1  key not found and no default given
#   2  bad arguments, missing `python3`, or JSON parse error

set -euo pipefail

key="${1:-}"
has_default=0
if [ $# -ge 2 ]; then
    has_default=1
    default="$2"
fi
config_file="${3:-.devflow/config.json}"

if [ -z "$key" ]; then
    echo "config-get.sh: usage: config-get.sh KEY [DEFAULT] [CONFIG_FILE]" >&2
    exit 2
fi

emit_default_or_fail() {
    if [ "$has_default" -eq 1 ]; then
        printf '%s\n' "$default"
        exit 0
    fi
    exit 1
}

if [ ! -f "$config_file" ]; then
    if [ "$has_default" -eq 1 ]; then
        printf '%s\n' "$default"
        exit 0
    fi
    echo "config-get.sh: config file not found: $config_file" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "config-get.sh: 'python3' is required to read $config_file" >&2
    exit 2
fi

# Walk the dot-path. Missing/null → empty stdout (caller applies default).
# Lists join with ',' (matches prior behavior, e.g. allowed_bots/watched_authors).
# coerce() reproduces the prior Node String()/Array.join semantics byte-for-byte:
# booleans emit lowercase true/false (NOT Python's True/False), null → empty,
# arrays comma-join their coerced elements, an object → "[object Object]".
value=$(DEVFLOW_KEY="${key#.}" DEVFLOW_CONFIG="$config_file" python3 -c '
import json, os, sys
try:
    with open(os.environ["DEVFLOW_CONFIG"], encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write("config-get.sh: " + str(e) + "\n")
    sys.exit(2)


def coerce(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        return ",".join(coerce(x) for x in v)
    if isinstance(v, dict):
        return "[object Object]"
    return str(v)


cur = data
for part in os.environ["DEVFLOW_KEY"].split("."):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(0)
    cur = cur[part]
if cur is None:
    sys.exit(0)
sys.stdout.write(coerce(cur))
')

if [ -z "$value" ]; then
    emit_default_or_fail
fi

printf '%s\n' "$value"
