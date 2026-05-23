#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-node-cache.sh — emit setup-node's `cache` + `cache-dependency-path`
# for a Node project that may live in a subdirectory.
#
# Lives next to action.yml (not in scripts/) so it travels with the composite
# action when install.sh copies `.github/actions/setup-project-env/` wholesale
# into an adopter repo — the action must stay self-contained.
#
# Args:
#   $1  node_version           — when empty, caching is off (both outputs empty),
#                                matching the setup-node "no node" case.
#   $2  node_working_directory — directory holding package.json/lockfile,
#                                relative to the runner workspace (cwd). Empty =
#                                repo root (the historical behavior).
#
# Output (stdout), exactly two lines for the caller to splice into GITHUB_OUTPUT:
#   node_cache=<npm|yarn|pnpm|>
#   node_cache_path=<lockfile path under the working directory, or empty>
#
# Lockfiles are probed relative to cwd, qualified by the working directory when
# set. Package-manager precedence mirrors action.yml and detect-project-tools.sh:
# pnpm → yarn → npm(package-lock) → npm(shrinkwrap). setup-node errors when
# `cache` is set with no lockfile, so caching stays off unless one is found.
set -euo pipefail

node_ver="${1:-}"
node_wd="${2:-}"

node_cache=""
node_cache_path=""

# Normalize the directory into a path prefix. Empty → no prefix, so the probed
# paths are byte-for-byte the current root-based ones (no regression). A
# non-empty dir gets exactly one trailing slash regardless of how it was passed.
prefix=""
if [ -n "$node_wd" ]; then
  prefix="${node_wd%/}/"
fi

if [ -n "$node_ver" ]; then
  if   [ -f "${prefix}pnpm-lock.yaml" ];      then node_cache="pnpm"; node_cache_path="${prefix}pnpm-lock.yaml"
  elif [ -f "${prefix}yarn.lock" ];           then node_cache="yarn"; node_cache_path="${prefix}yarn.lock"
  elif [ -f "${prefix}package-lock.json" ];   then node_cache="npm";  node_cache_path="${prefix}package-lock.json"
  elif [ -f "${prefix}npm-shrinkwrap.json" ]; then node_cache="npm";  node_cache_path="${prefix}npm-shrinkwrap.json"
  fi
fi

printf 'node_cache=%s\n' "$node_cache"
printf 'node_cache_path=%s\n' "$node_cache_path"
