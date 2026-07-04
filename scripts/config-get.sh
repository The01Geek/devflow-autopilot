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
#   CONFIG_FILE  when omitted, defaults to the repo-root .devflow/config.json
#                (git rev-parse --show-toplevel, falling back to pwd); an explicit
#                value is honored verbatim (issue #295)
#
# SHARED REPO-ROOT CONFIG CONTRACT (issue #295, supersedes the #275 cwd-relative
# contract): this resolver and scripts/workpad.py's in-process marker read both
# resolve the DEFAULT `.devflow/config.json` anchored to the git repo root
# (`git rev-parse --show-toplevel`, falling back to `pwd`), NOT relative to the
# current working directory — mirroring lib/config-source.sh. So a skill invoked
# from any subdirectory of the repo loads the consumer's root `.devflow/config.json`
# exactly as if invoked from the root; when cwd already IS the root the resolution
# is byte-for-byte unchanged. Keep the two readers in lockstep: they must resolve
# the same file for the same cwd. An explicit CONFIG_FILE (3rd arg) is honored
# verbatim — the root anchoring applies only to the default. (workpad.py cannot exec
# this .sh on Windows — [WinError 193] — so it re-implements the same repo-root read
# in Python via a native git subprocess; issue #275/#295.)
#
# Known limitation: `git rev-parse --show-toplevel` returns the NEAREST git root, so
# a nested git submodule/inner repo resolves to that inner root, and a monorepo whose
# `.devflow/` is deliberately not at the git root is not covered — consistent with
# config-source.sh; a walk-up-to-nearest-`.devflow/` resolver was declined for this fix.
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
# Anchor the DEFAULT config path to the git repo root (issue #295) — mirroring
# lib/config-source.sh:14 (`git rev-parse --show-toplevel 2>/dev/null || pwd`) — so a
# skill invoked from a subdirectory reads the consumer's ROOT .devflow/config.json
# instead of silently missing it. An explicit CONFIG_FILE (3rd arg) is honored
# verbatim; root anchoring applies only to the default. Each invocation forks
# `git rev-parse` (fast; git is a hard preflight prereq) — unlike config-source.sh,
# this standalone resolver cannot cache the root across its separate subprocesses.
if [ $# -ge 3 ]; then
    config_file="$3"
else
    if _devflow_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_devflow_root" ]; then
        :   # in a git repo — anchor to its root
    else
        # Not a git repo: fall back to cwd. Breadcrumb only when NEITHER a git root
        # NOR a .devflow/ dir can be located — the silent-drop class this fix closes.
        # (A git root with no .devflow/ is the normal unconfigured local case and
        # stays silent; the caller then applies its own default.)
        _devflow_root="$(pwd)"
        [ -d "${_devflow_root}/.devflow" ] || \
            echo "config-get.sh: not in a git repo and no .devflow/ at '${_devflow_root}'; using cwd fallback and defaults" >&2
    fi
    config_file="${_devflow_root}/.devflow/config.json"
fi

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
