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
  log "scaffolded $CONFIG — every value has a working default; edit it only to customize"
fi

# Ignore ONLY the ephemeral scratch dir (.devflow/tmp/), never the rest of
# .devflow/: config.json must be committed for the cloud tier to read it, and
# learnings/ (retrospectives) and the schema/example are tracked too. A scoped
# .devflow/.gitignore keeps this self-contained — no mutation of the repo-root
# .gitignore. Created only when absent so an adopter's edits survive re-runs.
GITIGNORE="$DEST/.gitignore"
if [ ! -f "$GITIGNORE" ]; then
  printf '%s\n' \
    '# DevFlow ephemeral scratch (review caches, weekly-loop temp files, issue' \
    '# drafts). Safe to delete; never commit. Everything else under .devflow/' \
    '# (config.json, learnings/, the schema/example) is intentionally tracked.' \
    '/tmp/' > "$GITIGNORE"
  log "wrote $GITIGNORE (ignores ephemeral .devflow/tmp/ scratch)"
fi

# Language-aware tool/runtime auto-population. Scans the target repo and merges
# the matching per-language presets into config.json (idempotent union — safe
# whether config.json was just scaffolded or kept). Lives in its own script so
# the dumb file-copy above stays inspection-free; best-effort, so a missing jq
# never blocks the scaffold. Both entry points (install.sh + /devflow:init)
# reach it through here, so detection can't drift between them.
DETECT="$SELF_DIR/detect-project-tools.sh"
if [ -x "$DETECT" ]; then
  bash "$DETECT" "$TARGET_ROOT" || log "auto-detection step failed (non-fatal); config left as-is."
else
  log "detect-project-tools.sh not found next to the scaffolder; skipping language auto-detection."
fi
