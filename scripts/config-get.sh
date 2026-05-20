#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Read a value from .github/project-config.yml.
#
# Usage: config-get.sh KEY [DEFAULT] [CONFIG_FILE]
#   KEY          dot-path like .docs.internal or .claude.workpad_marker
#                (leading dot optional). Arbitrary nesting depth supported —
#                the path is split on dots and walked through nested mappings.
#   DEFAULT      printed if key is absent or value is empty/null. Pass an
#                empty string ("") to explicitly request empty-on-missing.
#   CONFIG_FILE  defaults to .github/project-config.yml
#
# Requires python3 with PyYAML (same contract as the rest of devflow; see
# lib/conf.sh).
#
# Exit codes:
#   0  value (or default) printed to stdout
#   1  key not found and no default given
#   2  bad arguments or YAML parse error

set -euo pipefail

key="${1:-}"
has_default=0
if [ $# -ge 2 ]; then
    has_default=1
    default="$2"
fi
config_file="${3:-.github/project-config.yml}"

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

case "$key" in
    .*) ;;
    *) key=".$key" ;;
esac

value=$(python3 - "$key" "$config_file" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write("config-get.sh: PyYAML required\n")
    sys.exit(2)
key = sys.argv[1].lstrip('.')
try:
    with open(sys.argv[2]) as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    sys.stderr.write(f"config-get.sh: {e}\n")
    sys.exit(2)
cur = data
for part in key.split('.'):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(0)
    cur = cur[part]
if cur is None:
    sys.exit(0)
if isinstance(cur, list):
    print(",".join(str(v) for v in cur))
else:
    print(cur)
PY
)

if [ -z "$value" ]; then
    emit_default_or_fail
fi

printf '%s\n' "$value"
