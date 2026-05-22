#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# scaffold-config.sh — DevFlow's single config-scaffolding implementation.
#
# Drops the DevFlow config files into a repo's .devflow/ directory:
#   - config.json     scaffolded from config.example.json ONLY when absent
#                     (never clobbers an existing one — your IDs/secrets stay).
#   - config.schema.json  refreshed every run (editor autocomplete/validation).
#
# This is the ONE scaffolder. Both entry points call it so the behaviour can
# never drift between them:
#   - install.sh           (cloud tier — runs from a fresh clone, $SRC)
#   - the /devflow:init skill (local tier — runs from the plugin cache)
# Because both call here, the two coexist safely: whichever runs first creates
# config.json; the other preserves it (no-clobber) and only refreshes the schema.
#
# Templates are resolved RELATIVE TO THIS SCRIPT (../.devflow), so the script is
# self-locating wherever it ships (marketplace cache, vendored plugin, or a
# clone). The caller never has to tell us where the templates are.
#
# Usage: scaffold-config.sh [TARGET_REPO_ROOT]
#   TARGET_REPO_ROOT  where to write .devflow/ (default: git toplevel, else cwd)
#
# Exit codes:
#   0  config.json scaffolded or kept; schema refreshed
#   2  bad arguments, or the template files are missing next to the script
set -euo pipefail

log() { printf 'devflow-scaffold: %s\n' "$1"; }
die() { printf 'devflow-scaffold: %s\n' "$1" >&2; exit 2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SELF_DIR/../.devflow"
EXAMPLE="$TPL_DIR/config.example.json"
SCHEMA="$TPL_DIR/config.schema.json"

[ -f "$EXAMPLE" ] || die "template not found: $EXAMPLE (is the plugin install complete?)"
[ -f "$SCHEMA" ]  || die "template not found: $SCHEMA (is the plugin install complete?)"

TARGET_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DEST="$TARGET_ROOT/.devflow"
CONFIG="$DEST/config.json"

mkdir -p "$DEST"

# Schema is generated, never hand-edited — safe to overwrite every run so
# editors always validate against the current field set.
cp "$SCHEMA" "$DEST/config.schema.json"

if [ -f "$CONFIG" ]; then
  log "keeping existing $CONFIG"
else
  cp "$EXAMPLE" "$CONFIG"
  log "scaffolded $CONFIG — fill in the YOUR_* placeholders before enabling workflows"
fi

# Ensure the /devflow:implement trigger label exists in the repo. Adding this
# label to an issue is what starts claude-implement.yml, so it must exist.
# Best-effort: needs gh + auth + a repo remote; if any are missing we print a
# hint instead of failing (this whole block is guarded against `set -e`).
# Honours claude_implement.trigger_label (default "devflow:implement"), read
# from the config we just wrote/kept.
ensure_trigger_label() {
  local label="devflow:implement" tl=""
  if command -v jq >/dev/null 2>&1; then
    tl="$(jq -r '.claude_implement.trigger_label // empty' "$CONFIG" 2>/dev/null || true)"
  elif command -v node >/dev/null 2>&1; then
    tl="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((o.claude_implement&&o.claude_implement.trigger_label)||"")}catch(e){}' "$CONFIG" 2>/dev/null || true)"
  fi
  [ -n "$tl" ] && label="$tl"

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    log "gh not available/authenticated — create a '${label}' label manually (Issues → Labels) to enable label-triggered /devflow:implement"
    return 0
  fi

  # Resolve the repo gh would act on (from $TARGET_ROOT's remote) and target it
  # EXPLICITLY with --repo, naming it in every log line. Without this, a gh call
  # silently acts on whatever remote happens to be in scope — so running this
  # from a clone whose origin is a fork/upstream would create the label in the
  # wrong repo with no hint. If the slug can't be resolved (no remote), bail
  # with a hint rather than guess.
  local slug=""
  slug="$(cd "$TARGET_ROOT" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  if [ -z "$slug" ]; then
    log "no GitHub repo resolved for $TARGET_ROOT — create a '${label}' label manually (Issues → Labels) to enable label-triggered /devflow:implement"
    return 0
  fi

  if gh label list --repo "$slug" --limit 500 --json name --jq '.[].name' 2>/dev/null | grep -qxF "$label"; then
    log "trigger label '${label}' already exists in ${slug}"
  elif gh label create "$label" --repo "$slug" --color BFD4F2 \
          --description "Add to an issue to start /devflow:implement" >/dev/null 2>&1; then
    log "created trigger label '${label}' in ${slug}"
  else
    log "could not create trigger label '${label}' in ${slug} — create it manually (Issues → Labels) to enable label-triggered /devflow:implement"
  fi
}
ensure_trigger_label || true
