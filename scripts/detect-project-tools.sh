#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# detect-project-tools.sh — language-aware tool/runtime auto-population.
#
# Scans a repo for language marker files (package.json, go.mod, Cargo.toml, …),
# looks each match up in .devflow/tool-presets.json, and MERGES the union of the
# matching presets into the repo's .devflow/config.json:
#
#   - the build/test/lint tool patterns are added to three execution paths'
#     allowlists: devflow.allowed_tools (command) and devflow_implement.allowed_tools
#     (implement) are live; devflow_runner.allowed_tools is also populated but is
#     currently INERT — the automated reviewer's build access is the opt-in flag
#     devflow_runner.provision_env, not this list (see config.schema.json);
#   - the shared `setup` block gets node_version (only when currently empty — a
#     pinned version is never overridden) and a lockfile-appropriate install
#     line so the runtime the tools need actually exists before Claude runs;
#     when the Node lockfile lives in a subdirectory (monorepo / co-located JS
#     bundle) it also sets node_working_directory and scopes the install line
#     into that directory with a subshell `cd`.
#
# Idempotent UNION: existing entries are preserved (order kept, no duplicates),
# so re-running after adding a language picks up only the new tools — this is
# what makes the "run /devflow:init again after a plugin update" flow safe.
#
# This is called by scripts/scaffold-config.sh (the one shared scaffolder), so
# BOTH `/devflow:init` and install.sh get detection with no drift. Best-effort:
# a missing jq / presets file / config logs a notice and exits 0 — never blocks
# the scaffold.
#
# SECURITY: the devflow / devflow_implement allowlists written here run a PR
# author's code in their respective workflows. The automated reviewer instead
# runs PR build code only when the maintainer sets devflow_runner.provision_env
# (read from the BASE branch's committed config, never the PR head — see
# devflow-review.yml — so a PR cannot enable it for itself), which then runs
# setup.install + the PR's build under a write token. devflow_runner.allowed_tools
# is auto-populated but currently inert for the reviewer. Keep presets to
# mainstream toolchains and review the resulting config.json before committing.
#
# Usage: detect-project-tools.sh [TARGET_REPO_ROOT]
#   TARGET_REPO_ROOT  repo to scan + whose .devflow/config.json to update
#                     (default: git toplevel, else cwd)
#
# Exit codes: always 0 (best-effort). Non-fatal conditions log and skip.
set -euo pipefail

log() { printf 'devflow-detect: %s\n' "$1"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESETS="$SELF_DIR/../.devflow/tool-presets.json"

TARGET_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIG="$TARGET_ROOT/.devflow/config.json"

# Best-effort guards — never abort the surrounding scaffold.
if ! command -v jq >/dev/null 2>&1; then
  log "jq not found; skipping language auto-detection (install jq to enable it)."
  exit 0
fi
if [ ! -f "$PRESETS" ]; then
  log "preset registry not found at $PRESETS; skipping auto-detection."
  exit 0
fi
if [ ! -f "$CONFIG" ]; then
  log "no $CONFIG to update; skipping auto-detection."
  exit 0
fi

# --- 1. Detect which presets apply -----------------------------------------
# A preset matches when any of its marker files exists in the repo. Scan a few
# levels deep (covers monorepo sub-packages) but prune dependency/build dirs so
# a vendored marker (e.g. node_modules/**/package.json) never triggers a false
# positive and the walk stays fast. `-name` accepts globs (e.g. *.csproj).
marker_present() {
  local marker="$1" hit
  hit=$(find "$TARGET_ROOT" -maxdepth 3 \
          \( -name node_modules -o -name .git -o -name vendor -o -name target \
             -o -name dist -o -name build -o -name .venv \) -prune \
          -o -name "$marker" -print -quit 2>/dev/null || true)
  [ -n "$hit" ]
}

ACTIVE=()
while IFS= read -r key; do
  [ -n "$key" ] || continue
  matched=false
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    if marker_present "$marker"; then matched=true; break; fi
  done < <(jq -r --arg k "$key" '.presets[$k].markers[]?' "$PRESETS")
  $matched && ACTIVE+=("$key")
done < <(jq -r '.presets | keys[]' "$PRESETS")

if [ "${#ACTIVE[@]}" -eq 0 ]; then
  log "no known language markers detected; config.json left unchanged."
  exit 0
fi

ACTIVE_JSON=$(printf '%s\n' "${ACTIVE[@]}" | jq -R . | jq -s .)

# --- 2. Resolve pre-build install lines from the present lockfiles ----------
# Node and PHP need an explicit pre-build install line (npm/pnpm/yarn populate
# node_modules; composer populates vendor/) before the build/test/lint tools
# can run; other ecosystems fetch deps on first build. Pick the Node command
# matching the committed lockfile.

# Locate the Node lockfile, preferring the repo root (back-compat) and falling
# back to the first subdirectory lockfile (monorepo / co-located JS bundle under
# e.g. jsx/, resources/js/, frontend/). Same prune set as marker_present so a
# vendored node_modules lockfile never matches. Precedence pnpm → yarn → npm
# (package-lock) → npm (shrinkwrap) mirrors resolve-node-cache.sh and action.yml.
# When several subdirectories match the same manager, `-print -quit` returns
# whichever the filesystem yields first — the feature targets a single co-located
# bundle, so this is deterministic per checkout but not "nearest to root". Prints
# the path relative to TARGET_ROOT, or nothing when no lockfile exists.
find_node_lockfile() {
  local lf hit
  for lf in pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json; do
    [ -f "$TARGET_ROOT/$lf" ] && { printf '%s' "$lf"; return; }
  done
  for lf in pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json; do
    hit=$(find "$TARGET_ROOT" -maxdepth 3 \
            \( -name node_modules -o -name .git -o -name vendor -o -name target \
               -o -name dist -o -name build -o -name .venv \) -prune \
            -o -name "$lf" -print -quit 2>/dev/null || true)
    [ -n "$hit" ] && { printf '%s' "${hit#"$TARGET_ROOT"/}"; return; }
  done
  # No lockfile anywhere: return success with empty output (the bare-npm-install
  # case). Without this, the loop's final failed `[ -n "$hit" ]` would make the
  # function exit 1 and abort the script under `set -e`.
  return 0
}

EXTRA_INSTALL_JSON='[]'
NODE_WD=""   # empty = repo root; only set when the build lives in a subdirectory
if printf '%s\n' "${ACTIVE[@]}" | grep -qx node; then
  NODE_LOCKFILE="$(find_node_lockfile)"
  case "${NODE_LOCKFILE##*/}" in
    pnpm-lock.yaml)      NODE_CMD="pnpm install --frozen-lockfile" ;;
    yarn.lock)           NODE_CMD="yarn install --frozen-lockfile" ;;
    package-lock.json)   NODE_CMD="npm ci" ;;
    npm-shrinkwrap.json) NODE_CMD="npm ci" ;;   # npm ci honors npm-shrinkwrap.json
    *)                   NODE_CMD="npm install" ;;   # no lockfile found
  esac
  # dirname is "." for a root lockfile and for the no-lockfile case (empty
  # string), so both keep today's root-level install line and empty NODE_WD. A
  # subdirectory lockfile yields a subshell `cd` so a later root-level install
  # line in the same setup.install array is unaffected by the directory change.
  # The directory is single-quoted in the generated line so a path with a space
  # (e.g. a "resources/js" sibling) doesn't word-split when the install array is
  # exec'd via `bash -c` in the action.
  NODE_LOCKDIR="$(dirname "$NODE_LOCKFILE")"
  if [ -n "$NODE_LOCKFILE" ] && [ "$NODE_LOCKDIR" != "." ]; then
    NODE_WD="$NODE_LOCKDIR"
    NODE_INSTALL="(cd '$NODE_WD' && $NODE_CMD)"
  else
    NODE_INSTALL="$NODE_CMD"
  fi
  EXTRA_INSTALL_JSON=$(jq -n --arg c "$NODE_INSTALL" '[$c]')
fi
# composer install populates vendor/ so phpunit/phpstan/php-cs-fixer can run.
if printf '%s\n' "${ACTIVE[@]}" | grep -qx php && [ -f "$TARGET_ROOT/composer.json" ]; then
  EXTRA_INSTALL_JSON=$(printf '%s' "$EXTRA_INSTALL_JSON" \
    | jq -c '. + ["composer install --no-interaction --prefer-dist --no-progress"]')
fi

# --- 3. Merge into config.json (ordered union) ------------------------------
# `odedupe` appends only not-yet-present items, preserving existing order — so a
# maintainer's hand-tuned ordering (and install-line ordering, which matters)
# survives. `unique` is deliberately NOT used: it would alphabetically reorder
# install lines and break dependency-ordering assumptions.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

jq -n \
  --slurpfile cfg "$CONFIG" \
  --slurpfile pre "$PRESETS" \
  --argjson keys "$ACTIVE_JSON" \
  --argjson extra_install "$EXTRA_INSTALL_JSON" \
  --arg nodewd "$NODE_WD" '
  def odedupe: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  ($cfg[0]) as $c |
  ($pre[0].presets) as $p |
  ([ $keys[] as $k | $p[$k].allowed_tools[]? ]) as $tools |
  ([ $keys[] as $k | $p[$k].setup.install[]? ] + $extra_install) as $inst |
  ([ $keys[] as $k | $p[$k].setup.node_version? // empty ] | .[0]) as $nodever |
  $c
  | .devflow           = (.devflow           // {})
  | .devflow_implement  = (.devflow_implement  // {})
  | .devflow_runner     = (.devflow_runner     // {})
  | .setup             = (.setup             // {})
  | .devflow.allowed_tools           = ((.devflow.allowed_tools           // []) + $tools | odedupe)
  | .devflow_implement.allowed_tools = ((.devflow_implement.allowed_tools // []) + $tools | odedupe)
  | .devflow_runner.allowed_tools    = ((.devflow_runner.allowed_tools    // []) + $tools | odedupe)
  | .setup.install                  = ((.setup.install                  // []) + $inst  | odedupe)
  | (if ($nodever != null) and ((.setup.node_version // "") == "")
       then .setup.node_version = $nodever else . end)
  | (if ($nodewd != "") and ((.setup.node_working_directory // "") == "")
       then .setup.node_working_directory = $nodewd else . end)
  ' > "$TMP"

# Only rewrite when the merge actually changed something (keeps re-runs quiet
# and avoids touching the file's mtime for no reason).
if jq --sort-keys . "$CONFIG" >/dev/null 2>&1 && ! diff -q \
     <(jq --sort-keys . "$CONFIG") <(jq --sort-keys . "$TMP") >/dev/null 2>&1; then
  mv "$TMP" "$CONFIG"
  trap - EXIT
  log "detected: ${ACTIVE[*]} — merged build/test tools into config.json (devflow / devflow_implement / devflow_runner) + setup."
  log "review the additions before committing; the devflow / devflow_implement entries run PR code in their respective workflows. NOTE: devflow_runner.allowed_tools is currently inert — the automated reviewer's build access is the opt-in flag devflow_runner.provision_env (see config.schema.json / docs/cloud-setup.md), which also runs PR build code under a write token."
else
  log "detected: ${ACTIVE[*]} — config.json already covers them; no changes."
fi
