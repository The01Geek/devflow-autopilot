#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# scaffold-config.sh — DevFlow's single config-scaffolding implementation.
#
# Drops the DevFlow config files into a repo's .devflow/ directory:
#   - config.json     scaffolded from config.example.json when absent; when it
#                     already exists it's kept (your IDs/secrets stay) and only
#                     newly-introduced keys are backfilled from the example —
#                     existing values always win, your arrays are left as-is.
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

# Backfill newly-introduced keys into an EXISTING config.json. A recursive
# deep-merge ($example * $config) adds any key present in the example but absent
# from the repo's config — at any nesting depth (e.g. devflow_runner.provision_env)
# — so an in-place upgrade (re-run install.sh / /devflow:init) lets adopters
# discover and opt into new features instead of silently drifting behind the
# example. jq's `*` recurses objects with the RIGHT operand winning, so a value
# the user already set is never overwritten and an array they already have
# (e.g. allowed_tools) is kept with its exact contents (arrays are replaced by the
# right operand — the user's — not merged/reordered/deduped). Recursion stops
# wherever the user's value diverges in type from the example (e.g. a scalar where
# the example now nests an object): the user's value still wins wholesale, so
# nested defaults under it are NOT backfilled. A key the user deleted is re-added
# with its documented default; DevFlow doesn't track deletions.
# Best-effort, mirroring detect-project-tools.sh (trap-guarded temp, non-fatal
# logs): a missing jq, a malformed config.json, or a jq merge/compare failure logs
# and skips without aborting the scaffold. Only rewrites when the merge actually
# changes something, so an up-to-date config is a quiet no-op (no mtime churn).
# Runs before detection so the tool/setup union below operates on a config that
# already has the full key set.
if ! command -v jq >/dev/null 2>&1; then
  log "jq not found; skipping config-key backfill (install jq to migrate newly-added keys)."
elif ! jq -e . "$CONFIG" >/dev/null 2>&1; then
  log "existing $CONFIG is not valid JSON; skipping config-key backfill (fix or delete it to re-scaffold)."
else
  BACKFILL_TMP="$(mktemp)"
  trap 'rm -f "$BACKFILL_TMP"' EXIT
  if ! jq -n --slurpfile ex "$EXAMPLE" --slurpfile cfg "$CONFIG" '$ex[0] * $cfg[0]' \
        > "$BACKFILL_TMP" 2>/dev/null; then
    # A genuine merge failure (odd jq build, OOM, corrupt template) is logged and
    # skipped — never masked as a silent no-op, and never aborts the scaffold.
    log "config-key backfill merge failed (jq error); leaving $CONFIG unchanged."
  else
    # diff -q exit codes: 0 = identical (quiet no-op), 1 = differ (backfill added
    # keys), >1 = diff itself failed. Capture the code without tripping `set -e`
    # (a bare non-zero command would abort the script), and fail safe on >1 —
    # leave the config untouched rather than overwriting from a comparison we
    # can't trust.
    bf_rc=0
    diff -q <(jq --sort-keys . "$CONFIG") <(jq --sort-keys . "$BACKFILL_TMP") >/dev/null 2>&1 || bf_rc=$?
    if [ "$bf_rc" -eq 1 ]; then
      mv "$BACKFILL_TMP" "$CONFIG"
      log "backfilled newly-added keys into $CONFIG from the example (your values and arrays kept)."
    elif [ "$bf_rc" -gt 1 ]; then
      log "could not compare the merged config against $CONFIG; leaving it unchanged."
    fi
  fi
  rm -f "$BACKFILL_TMP"
  trap - EXIT
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
