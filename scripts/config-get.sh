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
# Parses with Node (`node`), which is guaranteed wherever the DevFlow plugin
# runs (Claude Code is a Node CLI) and preinstalled on GitHub runners — no
# Python, PyYAML, or yq required. This is the ONE config-reading implementation
# in DevFlow; lib/conf.sh delegates here.
#
# Exit codes:
#   0  value (or default) printed to stdout
#   1  key not found and no default given
#   2  bad arguments, missing `node`, or JSON parse error

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

if ! command -v node >/dev/null 2>&1; then
    echo "config-get.sh: 'node' is required to read $config_file" >&2
    exit 2
fi

# Walk the dot-path. Missing/null → empty stdout (caller applies default).
# Lists join with ',' (matches prior behavior, e.g. allowed_bots/watched_authors).
value=$(DEVFLOW_KEY="${key#.}" DEVFLOW_CONFIG="$config_file" node -e '
  const fs = require("fs");
  let data;
  try {
    data = JSON.parse(fs.readFileSync(process.env.DEVFLOW_CONFIG, "utf8"));
  } catch (e) {
    process.stderr.write("config-get.sh: " + e.message + "\n");
    process.exit(2);
  }
  let cur = data;
  for (const part of process.env.DEVFLOW_KEY.split(".")) {
    if (cur === null || typeof cur !== "object" || Array.isArray(cur) || !(part in cur)) {
      process.exit(0);
    }
    cur = cur[part];
  }
  if (cur === null || cur === undefined) process.exit(0);
  if (Array.isArray(cur)) process.stdout.write(cur.join(","));
  else process.stdout.write(String(cur));
')

if [ -z "$value" ]; then
    emit_default_or_fail
fi

printf '%s\n' "$value"
