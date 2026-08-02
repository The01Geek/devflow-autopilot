#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# config-source.sh — read settings from .prflow/config.json. Source, don't exec.
#   devflow_conf '.prflow_retrospective.min_occurrences' 2
#
# This is an ergonomic shell wrapper; the actual parsing is delegated to
# scripts/config-get.sh (the ONE config-reading implementation, python3-based —
# no PyYAML/yq, since config is JSON). config-source.sh never aborts the
# sourcing chain.
set -euo pipefail
# Repo root via git; fall back to cwd when not in a git tree (don't abort the
# sourcing chain under `set -e`).
_DEVFLOW_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Config path. Override with DEVFLOW_CONFIG_FILE (used by the test suite to
# point at a committed fixture instead of the live repo config).
# State-directory resolution (issue #1002): canonical .prflow/, with the LOUD
# transitional fallback to a superseded .devflow/ when only that one is present.
# Guarded source so a partially-copied deployment degrades to the canonical name
# with a breadcrumb rather than aborting the sourcing chain under `set -e`.
# Self-directory anchor. `dirname` is NOT one of the tools lib/preflight.sh
# guarantees, and under `set -e` its failing command substitution aborts the read
# before a caller default is emitted — so this uses the dirname-free spelling of
# the anchor, which is also one of the shapes lib/test/cloud_writer_deps.py can
# prove (a variable assigned by a `case` cannot be resolved by that scanner, so an
# edge built from one reads as a repo-root escape). `cd`/`pwd` are bash builtins.
_DEVFLOW_CONF_DIR_EARLY="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=resolve-state-dir.sh
if [ -f "${_DEVFLOW_CONF_DIR_EARLY}/resolve-state-dir.sh" ] \
   && . "${_DEVFLOW_CONF_DIR_EARLY}/resolve-state-dir.sh" \
   && type prflow_state_dir >/dev/null 2>&1; then
  :
else
  echo "config-source.sh: resolve-state-dir.sh not found beside this file — using the canonical .prflow/ with no transitional fallback" >&2
  prflow_state_dir() { printf '%s' "${1:-}/.prflow"; }
fi
_DEVFLOW_CONFIG="${DEVFLOW_CONFIG_FILE:-$(prflow_state_dir "${_DEVFLOW_REPO_ROOT}")/config.json}"
# Locate the resolver relative to this file (lib/ → ../scripts/).
_DEVFLOW_CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DEVFLOW_CONFIG_GET="${_DEVFLOW_CONF_DIR}/../scripts/config-get.sh"

# Read a dot-path, returning $default when the key/file is absent or the
# resolver fails (so a parse error or missing `python3` never aborts the caller).
# config-get.sh exit codes: 0 = value/default printed; 1 = key absent and no
# default; 2 = bad args / missing python3 / JSON parse error. Only exit 2 is a
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

# Watched authors → comma-separated. watched_authors override array > prflow.allowed_bots string.
devflow_watched_authors() {
  local arr
  arr="$(devflow_conf '.prflow_retrospective.watched_authors' '')"
  if [ -n "$arr" ]; then
    printf '%s' "$arr"
  else
    devflow_conf '.prflow.allowed_bots' ''
  fi
}

devflow_repo_root() { printf '%s' "$_DEVFLOW_REPO_ROOT"; }
