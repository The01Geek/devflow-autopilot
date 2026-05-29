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

# Atomically replace a config file with a candidate temp IFF their canonical
# (jq --sort-keys) forms differ — the shared "rewrite only on a real change"
# guard for both the backfill and the Haiku effort-cleanup passes below.
#   $1 config path   $2 candidate temp file
#   $3 log line on a successful rewrite
#   $4 log line when the comparison itself cannot be trusted
# Each side is normalized into a captured variable rather than compared via
# `diff -q <(jq …) <(jq …)`: process substitution hides the inner jq's exit
# status, so a left-hand normalization failure would read as "configs differ"
# and fire a phantom rewrite. Capturing lets us detect a jq failure explicitly
# and skip. The `mv` is guarded so a write failure (read-only FS, ENOSPC, an
# immutable file) logs-and-continues instead of aborting the whole best-effort
# scaffold under `set -euo pipefail`.
rewrite_config_if_changed() {
  local cfg="$1" cand="$2" changed_msg="$3" cmpfail_msg="$4"
  local cfg_norm cand_norm
  if ! cfg_norm="$(jq --sort-keys . "$cfg" 2>/dev/null)" \
     || ! cand_norm="$(jq --sort-keys . "$cand" 2>/dev/null)"; then
    log "$cmpfail_msg"
    return 0
  fi
  if [ "$cfg_norm" != "$cand_norm" ]; then
    if mv "$cand" "$cfg"; then
      log "$changed_msg"
    else
      log "could not write $cfg from a generated update; leaving it unchanged."
    fi
  fi
}

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
  if ! jq -n --slurpfile ex "$EXAMPLE" --slurpfile cfg "$CONFIG" '
        ($cfg[0].devflow_review.agent_overrides // {}) as $userao
        | ($ex[0] * $cfg[0])
        | if (.devflow_review.agent_overrides | type) == "object" then
            .devflow_review.agent_overrides |= with_entries(
              # Do NOT let the deep-merge GRAFT an effort from the example onto a
              # Haiku-pinned entry the user left effort-less. The shipped example
              # pins the deduper to Sonnet 4.6 WITH effort; merged onto a config that
              # re-pins that key to a Haiku id, the merge would add the effort from
              # the example (Claude Haiku rejects effort with HTTP 400) and re-graft
              # it on every re-scaffold, fighting the cleanup below forever. Strip
              # ONLY a grafted effort (Haiku model + effort present + the user
              # supplied none); a user-set stale effort is preserved here and
              # repaired by the dedicated Haiku effort-cleanup below, so that the
              # migration first-run behavior is unchanged. (NOTE: this comment lives
              # inside a single-quoted jq program — keep it apostrophe-free.)
              .key as $k
              | if (.value | type) == "object"
                   and ((.value.model // "") | startswith("claude-haiku-"))
                   and (.value | has("effort"))
                   and (($userao[$k] // {}) | (type == "object" and has("effort")) | not)
                then .value |= del(.effort) else . end)
          else . end' \
        > "$BACKFILL_TMP" 2>/dev/null; then
    # A genuine merge failure (odd jq build, OOM, corrupt template) is logged and
    # skipped — never masked as a silent no-op, and never aborts the scaffold.
    log "config-key backfill merge failed (jq error); leaving $CONFIG unchanged."
  else
    # Rewrite only when the merge actually changed something; a jq normalization
    # failure leaves the config untouched (fail-safe) rather than overwriting
    # from a comparison we can't trust. See rewrite_config_if_changed.
    rewrite_config_if_changed "$CONFIG" "$BACKFILL_TMP" \
      "backfilled newly-added keys into $CONFIG from the example (your values and arrays kept)." \
      "could not compare the merged config against $CONFIG; leaving it unchanged."
  fi
  rm -f "$BACKFILL_TMP"
  trap - EXIT
fi

# Repair model/effort combinations the model API rejects but the no-clobber
# backfill above structurally cannot fix. The shipped example once pinned the
# checklist-deduper to a Haiku id and (pre-#77) carried an `effort` key on it;
# the example now defaults that override to Sonnet 4.6, but a key *removal* never
# propagates through the backfill — it only ADDS keys, never deletes (see the
# deletion-tracking note above). So an adopter who scaffolded earlier silently
# keeps `effort` on a Haiku override (their own deduper pin, or any other agent
# they pinned to Haiku), which Claude Haiku rejects with HTTP 400 (effort is
# supported only on Opus 4.5–4.8 / Sonnet 4.6). This data-driven cleanup drops
# `effort` from any agent_overrides entry whose `model` is a Haiku id — narrow
# (only that combination), idempotent, and best-effort with the same mtime-churn
# guard as the backfill: an already-clean config is a quiet no-op. Lives here,
# not in the backfill, because it removes a key rather than adding one. (The
# backfill separately refuses to GRAFT the example's Sonnet-deduper effort onto a
# Haiku-pinned entry, so the two passes never churn against each other on a
# re-scaffold.)
if command -v jq >/dev/null 2>&1 && jq -e . "$CONFIG" >/dev/null 2>&1; then
  # Anti-silent-failure breadcrumb: if agent_overrides exists but is not an
  # object (hand-corrupted to an array/string/scalar), the cleanup filter below
  # no-ops via its `else .` arm. Surface that we saw it and skipped, so the
  # silence is not an ambiguous "nothing to do". Capture the probe's exit status
  # (via `|| ao_rc=$?`, which keeps the failing assignment off `set -e`) instead
  # of folding a jq error into "null" with `|| printf 'null'`: when `devflow_review`
  # ITSELF is a non-object (e.g. a string), `.agent_overrides` indexing errors
  # (rc≠0) rather than yielding "null", and the old fold suppressed this very
  # breadcrumb — leaving only the generic "cleanup failed (jq error)" line below
  # to (mis)explain a corrupt config. Distinguish probe-error from genuinely-absent.
  ao_rc=0
  ao_type="$(jq -r '.devflow_review.agent_overrides | type' "$CONFIG" 2>/dev/null)" || ao_rc=$?
  if [ "$ao_rc" -ne 0 ]; then
    log "could not inspect .devflow_review.agent_overrides in $CONFIG (jq error — is devflow_review itself a non-object?); skipping Haiku effort-cleanup."
  elif [ "$ao_type" != "object" ] && [ "$ao_type" != "null" ]; then
    log "agent_overrides is present but not an object ($ao_type); skipping Haiku effort-cleanup."
  fi
  CLEANUP_TMP="$(mktemp)"
  trap 'rm -f "$CLEANUP_TMP"' EXIT
  if ! jq '
        if (.devflow_review.agent_overrides | type) == "object" then
          .devflow_review.agent_overrides |= with_entries(
            if (.value | type) == "object"
               and ((.value.model // "") | startswith("claude-haiku-"))
               and (.value | has("effort"))
            then .value |= del(.effort) else . end)
        else . end' "$CONFIG" > "$CLEANUP_TMP" 2>/dev/null; then
    log "Haiku effort-cleanup failed (jq error); leaving $CONFIG unchanged."
  else
    rewrite_config_if_changed "$CONFIG" "$CLEANUP_TMP" \
      "removed unsupported 'effort' from Haiku-pinned agent_overrides in $CONFIG (Claude Haiku rejects effort with HTTP 400)." \
      "could not compare the Haiku effort-cleanup against $CONFIG; leaving it unchanged."
  fi
  rm -f "$CLEANUP_TMP"
  trap - EXIT
else
  # The backfill block above already logs the specific reason (jq missing /
  # invalid JSON) for the same guard; this one-liner keeps the Haiku migration
  # from being silently dependent on that block for its own skip breadcrumb.
  log "skipping Haiku effort-cleanup (jq missing or $CONFIG not valid JSON)."
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
