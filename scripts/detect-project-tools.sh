#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# detect-project-tools.sh — language-aware tool/runtime auto-population.
#
# Scans a repo for language marker files (package.json, go.mod, Cargo.toml, …),
# looks each match up in .devflow/tool-presets.json, and MERGES the union of the
# matching presets into the repo's .devflow/config.json:
#
#   - the build/test/lint tool patterns are added to ALL three execution paths'
#     allowlists: claude.allowed_tools (command), claude_implement.allowed_tools
#     (implement), and claude_runner.allowed_tools (the automated reviewer);
#   - the shared `setup` block gets node_version (only when currently empty — a
#     pinned version is never overridden) and a lockfile-appropriate install
#     line so the runtime the tools need actually exists before Claude runs.
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
# SECURITY: the tools written here run a PR author's code during the automated
# review (pull_request_target + write token). The reviewer reads them from the
# BASE branch's committed config (never the PR head — see devflow-review.yml),
# so a PR cannot grant itself tools; but a maintainer enabling, say, Bash(npm:*)
# is opting into running untrusted postinstall scripts. Keep presets to
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
EXTRA_INSTALL_JSON='[]'
if printf '%s\n' "${ACTIVE[@]}" | grep -qx node; then
  if   [ -f "$TARGET_ROOT/pnpm-lock.yaml" ]; then NODE_INSTALL="pnpm install --frozen-lockfile"
  elif [ -f "$TARGET_ROOT/yarn.lock" ];      then NODE_INSTALL="yarn install --frozen-lockfile"
  elif [ -f "$TARGET_ROOT/package-lock.json" ]; then NODE_INSTALL="npm ci"
  else NODE_INSTALL="npm install"
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
  --argjson extra_install "$EXTRA_INSTALL_JSON" '
  def odedupe: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  ($cfg[0]) as $c |
  ($pre[0].presets) as $p |
  ([ $keys[] as $k | $p[$k].allowed_tools[]? ]) as $tools |
  ([ $keys[] as $k | $p[$k].setup.install[]? ] + $extra_install) as $inst |
  ([ $keys[] as $k | $p[$k].setup.node_version? // empty ] | .[0]) as $nodever |
  $c
  | .claude            = (.claude            // {})
  | .claude_implement  = (.claude_implement  // {})
  | .claude_runner     = (.claude_runner     // {})
  | .setup             = (.setup             // {})
  | .claude.allowed_tools           = ((.claude.allowed_tools           // []) + $tools | odedupe)
  | .claude_implement.allowed_tools = ((.claude_implement.allowed_tools // []) + $tools | odedupe)
  | .claude_runner.allowed_tools    = ((.claude_runner.allowed_tools    // []) + $tools | odedupe)
  | .setup.install                  = ((.setup.install                  // []) + $inst  | odedupe)
  | (if ($nodever != null) and ((.setup.node_version // "") == "")
       then .setup.node_version = $nodever else . end)
  ' > "$TMP"

# Only rewrite when the merge actually changed something (keeps re-runs quiet
# and avoids touching the file's mtime for no reason).
if jq --sort-keys . "$CONFIG" >/dev/null 2>&1 && ! diff -q \
     <(jq --sort-keys . "$CONFIG") <(jq --sort-keys . "$TMP") >/dev/null 2>&1; then
  mv "$TMP" "$CONFIG"
  trap - EXIT
  log "detected: ${ACTIVE[*]} — merged build/test tools into config.json (claude / claude_implement / claude_runner) + setup."
  log "review the additions before committing; these tools run PR code during automated review (see config.schema.json claude_runner.allowed_tools)."
else
  log "detected: ${ACTIVE[*]} — config.json already covers them; no changes."
fi
