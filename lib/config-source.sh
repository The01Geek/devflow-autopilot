#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# config-source.sh — read settings from .devflow/config.json. Source, don't exec.
#   devflow_conf '.devflow_retrospective.min_occurrences' 2
#
# This is an ergonomic shell wrapper; the actual parsing is delegated to
# scripts/config-get.sh (the ONE config-reading implementation, Node-based —
# no Python/PyYAML/yq). config-source.sh never aborts the sourcing chain.
set -euo pipefail
# Repo root via git; fall back to cwd when not in a git tree (don't abort the
# sourcing chain under `set -e`).
_DEVFLOW_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Config path. Override with DEVFLOW_CONFIG_FILE (used by the test suite to
# point at a committed fixture instead of the live repo config).
_DEVFLOW_CONFIG="${DEVFLOW_CONFIG_FILE:-${_DEVFLOW_REPO_ROOT}/.devflow/config.json}"
# Locate the resolver relative to this file (lib/ → ../scripts/).
_DEVFLOW_CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DEVFLOW_CONFIG_GET="${_DEVFLOW_CONF_DIR}/../scripts/config-get.sh"

# Read a dot-path, returning $default when the key/file is absent or the
# resolver fails (so a parse error or missing `node` never aborts the caller).
# config-get.sh exit codes: 0 = value/default printed; 1 = key absent and no
# default; 2 = bad args / missing node / JSON parse error. Only exit 2 is a
# genuine failure — re-emit it as a ::warning:: so a malformed config.json
# doesn't silently degrade every value to its default with no breadcrumb.
devflow_conf() {
  local path="$1" default="${2-}" val rc err
  set +e
  err="$(mktemp)"   # inside set +e: a mktemp failure must not abort the caller
  val="$("$_DEVFLOW_CONFIG_GET" "$path" "$default" "$_DEVFLOW_CONFIG" 2>"$err")"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    echo "::warning::devflow_conf: config read failed for '${path}': $(cat "$err")" >&2
    val="$default"
  elif [ "$rc" -ne 0 ]; then
    val="$default"
  fi
  rm -f "$err"
  printf '%s' "$val"
}

# Watched authors → comma-separated. devflow override array > claude.allowed_bots string.
devflow_watched_authors() {
  local arr
  arr="$(devflow_conf '.devflow_retrospective.watched_authors' '')"
  if [ -n "$arr" ]; then
    printf '%s' "$arr"
  else
    devflow_conf '.claude.allowed_bots' ''
  fi
}

devflow_repo_root() { printf '%s' "$_DEVFLOW_REPO_ROOT"; }
