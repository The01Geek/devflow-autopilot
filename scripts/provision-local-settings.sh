#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# provision-local-settings.sh — provision a consumer repo's PROJECT
# .claude/settings.json with DevFlow's local/interactive-tier conveniences.
#
# Invoked ONLY from the /devflow:init skill flow — never from scaffold-config.sh
# or install.sh. The cloud (CI) tier runs under claude-code-action with its own
# deterministic allowlist profile and consumes neither a local marketplace
# install nor a local permission mode, so a settings file there is pointless;
# keeping this out of the shared scaffolder is what guarantees a cloud-only
# install.sh run writes no .claude/settings.json (issue #88, AC 7).
#
# It deep-merges three key groups into the project settings, additively and
# WITHOUT clobbering any value the user already set:
#   - extraKnownMarketplaces["devflow-marketplace"]  (a github source for
#       The01Geek/devflow-autopilot + autoUpdate:true) and
#       enabledPlugins["devflow@devflow-marketplace"]=true, so Claude Code keeps
#       the DevFlow plugin updated;
#   - env.CLAUDE_CODE_ENABLE_AUTO_MODE="1", which makes the `auto` permission
#       mode SELECTABLE in the Shift+Tab cycle on Bedrock/Vertex/Foundry (a
#       harmless no-op on the Anthropic API, where auto mode is already
#       available). It does NOT make auto mode the default and does NOT
#       guarantee it is usable (plan/model/admin gates still apply) — we never
#       write permissions.defaultMode. Per Claude Code's settings model the env
#       var is honored from PROJECT scope (it has no scope restriction), unlike
#       defaultMode:auto which project scope deliberately ignores.
#
# Mirrors scaffold-config.sh's contract: deterministic, idempotent, never
# clobbers user values, prints a stable `devflow-settings:` breadcrumb per
# outcome, and is safe to re-run. The merge is `$defaults * $existing` (jq deep
# merge with the user's value winning at every depth), so a key the user already
# set is preserved and only the absent keys are filled.
#
# Usage: provision-local-settings.sh [TARGET_REPO_ROOT]
#   TARGET_REPO_ROOT  repo root to provision (default: git toplevel, else cwd)
#
# Exit codes:
#   0  settings provisioned, or already complete (a quiet "nothing changed").
#   2  the existing .claude/settings.json is present but not valid JSON (left
#      byte-for-byte unchanged — fix or remove it, then re-run), or jq is
#      missing, or a temp file could not be created.
set -euo pipefail

log()  { printf 'devflow-settings: %s\n' "$1"; }
warn() { printf 'devflow-settings: %s\n' "$1" >&2; }

TARGET_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SETTINGS_DIR="$TARGET_ROOT/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found; cannot provision $SETTINGS (install jq, then re-run /devflow:init)."
  exit 2
fi

# The DevFlow defaults as a JSON literal. The merge below is `$defaults *
# $existing`, so the user's value wins at every depth and only keys they have
# not set are filled. permissions.defaultMode is intentionally absent — auto
# mode is made selectable, never made the default.
DEFAULTS='{
  "extraKnownMarketplaces": {
    "devflow-marketplace": {
      "source": { "source": "github", "repo": "The01Geek/devflow-autopilot" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "devflow@devflow-marketplace": true },
  "env": { "CLAUDE_CODE_ENABLE_AUTO_MODE": "1" }
}'

# Resolve the existing settings into a JSON value to merge against.
#   - absent file                  -> start from {} (create it)
#   - empty / whitespace-only file -> benign, treat as {} (fill the keys)
#   - non-empty, parses as JSON    -> use it verbatim
#   - non-empty, does NOT parse    -> MALFORMED: bail without touching the file
EXISTING='{}'
if [ -f "$SETTINGS" ]; then
  if [ -s "$SETTINGS" ] && grep -q '[^[:space:]]' "$SETTINGS"; then
    if ! EXISTING="$(jq . "$SETTINGS" 2>/dev/null)"; then
      warn "existing $SETTINGS is not valid JSON; left it unchanged and provisioned nothing (fix or remove it, then re-run /devflow:init)."
      exit 2
    fi
  fi
fi

# Which of the three DevFlow markers were ABSENT before the merge — used only to
# word the breadcrumb. `try ... catch false` keeps a hand-corrupted non-object
# value (e.g. env set to a string) from aborting the probe.
PRESENT_FLAGS="$(printf '%s' "$EXISTING" | jq -r '
  [ (try (.extraKnownMarketplaces["devflow-marketplace"] != null) catch false),
    (try (.enabledPlugins["devflow@devflow-marketplace"] != null) catch false),
    (try (.env.CLAUDE_CODE_ENABLE_AUTO_MODE != null) catch false) ]
  | map(if . then "1" else "0" end) | join("")')"

added=()
[ "${PRESENT_FLAGS:0:1}" = "0" ] && added+=("extraKnownMarketplaces[devflow-marketplace]")
[ "${PRESENT_FLAGS:1:1}" = "0" ] && added+=("enabledPlugins[devflow@devflow-marketplace]")
[ "${PRESENT_FLAGS:2:1}" = "0" ] && added+=("env.CLAUDE_CODE_ENABLE_AUTO_MODE")

MERGED="$(jq -n --argjson defaults "$DEFAULTS" --argjson existing "$EXISTING" '$defaults * $existing')"

# Only write on a real change (idempotent — no mtime churn on a re-run). Compare
# canonical (sorted) forms so formatting differences never read as a change.
if [ "$(printf '%s' "$EXISTING" | jq -S .)" = "$(printf '%s' "$MERGED" | jq -S .)" ]; then
  log ".claude/settings.json already has the DevFlow keys; nothing changed."
  exit 0
fi

mkdir -p "$SETTINGS_DIR"
TMP="$(mktemp "$SETTINGS_DIR/.settings.json.XXXXXX")" || {
  warn "could not create a temp file in $SETTINGS_DIR; left $SETTINGS unchanged."
  exit 2
}
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$MERGED" > "$TMP"
mv "$TMP" "$SETTINGS"
trap - EXIT

if [ "${#added[@]}" -gt 0 ]; then
  joined="$(printf '%s, ' "${added[@]}")"; joined="${joined%, }"
  log "provisioned $SETTINGS (added: $joined). Auto mode is now selectable, not on. Review the change before committing."
else
  log "provisioned $SETTINGS (backfilled missing DevFlow setting sub-keys). Review the change before committing."
fi
