#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Read a value from .devflow/config.json — DevFlow's single config resolver.
#
# Usage: config-get.sh KEY [DEFAULT] [CONFIG_FILE]
#   KEY          dot-path like .docs.internal or .claude.workpad_marker
#                (leading dot optional). Arbitrary nesting depth supported —
#                the path is split on dots and walked through nested objects.
#   DEFAULT      printed if key is absent or value is empty/null. Pass an
#                empty string ("") to explicitly request empty-on-missing.
#   CONFIG_FILE  defaults to .devflow/config.json
#
# Parses with jq — no Node, Python, PyYAML, or yq required.
# This is the ONE config-reading implementation in DevFlow;
# lib/config-source.sh delegates here.
#
# Exit codes:
#   0  value (or default) printed to stdout
#   1  key not found and no default given (an empty-string default still exits 0)
#   2  bad arguments or JSON parse error

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

# Walk the dot-path via jq getpath. Missing/null → empty stdout (caller applies
# default). Arrays join with ',' (e.g. allowed_bots/watched_authors). A scalar
# mid-path (try…catch null) yields empty rather than a jq error.
value="$(DEVFLOW_KEY="${key#.}" jq -r '
  ( env.DEVFLOW_KEY | split(".") ) as $parts
  | try ( getpath($parts) ) catch null
  | if   . == null         then ""
    elif (type == "array")  then map(tostring) | join(",")
    elif (type == "object") then ""
    else tostring end
' "$config_file" 2>/dev/null)" || { echo "config-get.sh: failed to parse $config_file" >&2; exit 2; }

if [ -z "$value" ]; then
    emit_default_or_fail
fi

printf '%s\n' "$value"
