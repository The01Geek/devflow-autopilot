#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# conf.sh — read settings from .github/project-config.yml. Source, don't exec.
#   devflow_conf '.devflow_retrospective.min_occurrences' 2
set -euo pipefail
# Repo root via git; fall back to cwd when not in a git tree (don't abort the
# sourcing chain under `set -e`).
_DEVFLOW_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Config path. Override with DEVFLOW_CONFIG_FILE (used by the test suite to
# point at a committed fixture instead of the live repo config).
_DEVFLOW_CONFIG="${DEVFLOW_CONFIG_FILE:-${_DEVFLOW_REPO_ROOT}/.github/project-config.yml}"

# Internal: resolve a dot-path from the YAML config via python3 (yq fallback).
# python3 + PyYAML is available on all supported systems; yq may not be installed.
_devflow_conf_read() {
  local path="$1"
  python3 - "$_DEVFLOW_CONFIG" "$path" <<'PYEOF'
import sys, yaml

def resolve_path(data, path):
    keys = path.lstrip('.').split('.')
    val = data
    for k in keys:
        if isinstance(val, dict) and k in val:
            val = val[k]
        else:
            return None
    return val

config_file = sys.argv[1]
path = sys.argv[2]
# Missing config file is the expected "no config" path (the local tier needs
# none) — return __none__ silently so callers apply their defaults, rather than
# raising and emitting a noisy ::warning:: traceback.
try:
    with open(config_file) as f:
        data = yaml.safe_load(f) or {}
except FileNotFoundError:
    print("__none__")
    sys.exit(0)
val = resolve_path(data, path)
if val is None:
    print("__none__")
elif isinstance(val, list):
    print(",".join(str(v) for v in val))
else:
    print(val)
PYEOF
}

# Internal: _devflow_conf_read, but never aborts the caller — on helper failure
# it emits a ::warning:: and echoes "__none__" so callers can apply a default.
_devflow_conf_read_checked() {
  local path="$1" val exit_code _err_tmp
  _err_tmp="$(mktemp)"
  set +e
  val="$(_devflow_conf_read "$path" 2>"$_err_tmp")"
  exit_code=$?
  set -e
  if [ $exit_code -ne 0 ]; then
    echo "::warning::devflow_conf: python helper failed for path '${path}': $(cat "$_err_tmp")" >&2
    val="__none__"
  fi
  rm -f "$_err_tmp"
  printf '%s' "$val"
}

devflow_conf() {
  local path="$1" default="${2-}" val
  val="$(_devflow_conf_read_checked "$path")"
  if [ "$val" = "__none__" ] || [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# Watched authors → comma-separated. devflow override array > claude.allowed_bots string.
devflow_watched_authors() {
  local arr
  arr="$(_devflow_conf_read_checked '.devflow_retrospective.watched_authors')"
  if [ -n "$arr" ] && [ "$arr" != "__none__" ]; then
    printf '%s' "$arr"
  else
    devflow_conf '.claude.allowed_bots' ''
  fi
}

devflow_repo_root() { printf '%s' "$_DEVFLOW_REPO_ROOT"; }
