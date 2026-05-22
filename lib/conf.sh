#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# conf.sh — read settings from .devflow/config.json. Source, don't exec.
#   devflow_conf '.devflow_retrospective.min_occurrences' 2
#
# This is an ergonomic shell wrapper; the actual parsing is delegated to
# scripts/config-get.sh (the ONE config-reading implementation, Node-based —
# no Python/PyYAML/yq). conf.sh never aborts the sourcing chain.
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
devflow_conf() {
  local path="$1" default="${2-}" val
  val="$("$_DEVFLOW_CONFIG_GET" "$path" "$default" "$_DEVFLOW_CONFIG" 2>/dev/null)" || val="$default"
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
