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
# immutable file) logs-and-continues — surfacing the underlying cause — instead
# of aborting the whole best-effort scaffold under `set -euo pipefail`.
rewrite_config_if_changed() {
  local cfg="$1" cand="$2" changed_msg="$3" cmpfail_msg="$4"
  local cfg_norm cand_norm mv_err
  if ! cfg_norm="$(jq --sort-keys . "$cfg" 2>/dev/null)" \
     || ! cand_norm="$(jq --sort-keys . "$cand" 2>/dev/null)"; then
    log "$cmpfail_msg"
    return 0
  fi
  if [ "$cfg_norm" != "$cand_norm" ]; then
    if mv_err="$(mv "$cand" "$cfg" 2>&1)"; then
      log "$changed_msg"
    else
      log "could not write $cfg from a generated update${mv_err:+ ($mv_err)}; leaving it unchanged."
    fi
  fi
}

# Testability hook: sourcing this script with DEVFLOW_SCAFFOLD_LIB_ONLY set loads
# the helpers above (log/die/rewrite_config_if_changed) for unit tests WITHOUT
# running the scaffold. The variable is never set in normal CLI/install/init
# invocations, so this is a no-op there.
if [ -n "${DEVFLOW_SCAFFOLD_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

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

# Consumer-owned prompt-extensions directory (issue #84, extended in issue #95).
# Skills load .devflow/prompt-extensions/<skill-name>.md verbatim when present, so a
# repo can append repo-specific instructions to any skill with no plugin edit.
# Scaffold one COMMENTED, INERT <skill>.md.example PER SKILL so adopters discover
# that EVERY skill is extensible, not just create-issue. The `.example` suffix keeps
# each file from matching `<skill-name>.md`, so it never injects itself into a real
# run until a consumer deliberately renames it; and the whole body is an HTML
# comment, so even a misrename that drops `.example` injects no actionable
# instruction. mkdir -p is idempotent; the absence guard is PER FILE (not on the
# directory), so an adopter who scaffolded before issue #95 — and so has only
# create-issue.md.example — gets the remaining examples backfilled on re-run, while
# any file they created or edited (an .example OR a live <skill>.md) is never
# touched. The directory is intentionally NOT gitignored (the scoped
# .devflow/.gitignore ignores only tmp/), so a team commits and shares its
# extensions.
#
# The skill list below is authoritative and is kept in sync with skills/ by a drift
# guard in lib/test/run.sh (it derives the expected set from skills/*/ and fails if
# the scaffolder forgets one). Each row is <skill-name>|<one-line hint>. Keep both
# fields apostrophe-free ASCII: a hint reaches a printf arg below, and an ASCII
# apostrophe in a single-quoted bash string would terminate it (shellcheck
# SC1073/SC1011) while a curly apostrophe would trip SC1112 (see CLAUDE.md).
EXTENSIONS_DIR="$DEST/prompt-extensions"
# Guard the directory create like every other write in this file: a failure
# (read-only .devflow, ENOSPC, perms) logs-and-skips the prompt-extension scaffolding
# rather than aborting the whole best-effort scaffold under `set -euo pipefail` (the
# documented contract at the top of this file). `mkdir -p` on an already-present
# directory is a success no-op, so this is idempotent.
if ! pe_mkdir_err="$(mkdir -p "$EXTENSIONS_DIR" 2>&1)"; then
  log "could not create $EXTENSIONS_DIR${pe_mkdir_err:+ ($pe_mkdir_err)}; skipping prompt-extension example scaffolding (scaffold continues)."
else
  pe_created=0
  while IFS='|' read -r pe_skill pe_hint; do
    [ -n "$pe_skill" ] || continue
    pe_target="$EXTENSIONS_DIR/$pe_skill.md.example"
    pe_live="$EXTENSIONS_DIR/$pe_skill.md"
    # Per-file backfill, two guards (issue #118): skip when the .example already exists
    # (an adopter's edited example — never clobber it), AND skip when a LIVE <skill>.md
    # already exists (the adopter activated this extension, so dropping a redundant
    # <skill>.md.example beside it is just confusing clutter). Both are plain `continue`s,
    # so neither introduces a command whose non-zero exit could abort the loop under
    # `set -euo pipefail`; the live <skill>.md is read-only here (never created, modified,
    # or deleted), and only absent .example files for un-activated skills are created.
    if [ -e "$pe_target" ] || [ -e "$pe_live" ]; then
      continue
    fi
    # The body is itself one Markdown comment block: the first line opens `<!--`, the
    # last closes `-->`. printf '%s\n' prints each argument on its own line, so the
    # static lines (single-quoted, apostrophe-free ASCII) and the two interpolated
    # lines ($pe_skill / $pe_hint, double-quoted) compose in a single call.
    #
    # Write to a temp then `mv` into place ATOMICALLY — the same write-candidate-then-mv
    # idiom rewrite_config_if_changed uses above. This is the log-and-continue contract
    # (a per-file failure must not abort the whole scaffold under `set -e`: the `if`
    # condition exempts the failure, and the breadcrumb names the file) PLUS atomicity:
    # the final `<skill>.md.example` only ever appears complete, so a failed/partial
    # write (read-only dir, ENOSPC mid-write) can never leave a truncated file at the
    # guarded path that the `[ -e ]` guard above would then treat as present and never
    # retry. On failure only the temp is removed; the guarded path is untouched.
    pe_tmp="$pe_target.tmp"
    if printf '%s\n' \
      '<!--' \
      "DevFlow prompt-extension example for the $pe_skill skill." \
      '' \
      'This directory holds consumer-owned prompt extensions for DevFlow skills.' \
      'Drop a file named <skill-name>.md here (no .example suffix) and its contents' \
      'are appended VERBATIM to the end of that skill prompt every time it runs. It' \
      'is an upgrade-safe way to add repo-specific instructions without forking the' \
      'plugin. Marketplace updates never touch this directory. When no file exists' \
      'for a skill, that skill behaves exactly as it does today (the no-op path).' \
      '' \
      "Useful extension for $pe_skill: $pe_hint" \
      '' \
      'To activate, copy this file to the same name without the .example suffix' \
      '(for example create-issue.md.example becomes create-issue.md) and replace' \
      'this comment with your own instructions. For the full convention and a' \
      'worked example, see the "Extending skills with prompt extensions" section' \
      'in docs/DEVFLOW_SYSTEM_OVERVIEW.md.' \
      '-->' > "$pe_tmp" && mv "$pe_tmp" "$pe_target"; then
      pe_created=$((pe_created + 1))
    else
      # Remove only the temp candidate — never a partial $pe_target (mv is atomic, so
      # the guarded path was never partially written). A lingering temp is harmless: it
      # ends in .tmp (not .md.example), so it matches neither the loader nor the
      # backfill `[ -e "$pe_target" ]` guard, and a later re-run truncates it anew.
      rm -f "$pe_tmp"
      log "could not write $pe_target; skipping this prompt-extension example (scaffold continues)."
    fi
  done <<'PE_SKILLS'
create-issue|extend the generated issue body with links to your house tracker or test-case system
docs|point the docs pass at extra documentation roots specific to your repo
docs-bootstrap-external|describe your public docs-site structure so the external bootstrap matches it
docs-bootstrap-internal|name the internal doc conventions and directory layout your team follows
docs-release-notes|match your release-notes house style, audience, and changelog format
docs-sync-external|list which internal sections are confidential and must never reach external docs
docs-sync-internal|flag the code areas whose internal docs your team keeps especially current
docs-verify|name the topics whose internal docs your team treats as load-bearing
implement|add repo-specific implementation constraints the orchestrator must honor
init|add post-scaffold setup steps unique to your repo
pr-description|enforce your PR-description template sections and required labels
retrospective|add house criteria for what counts as a clean PR in the retrospective
retrospective-audit|name the intervention patterns your team prioritizes when auditing
retrospective-weekly|tune which authors and time window the weekly loop scans
review|add house review rules the reviewer must enforce
review-and-fix|add house review rules and fix-loop guardrails specific to your repo
PE_SKILLS
  if [ "$pe_created" -gt 0 ]; then
    log "created/backfilled $pe_created prompt-extension example(s) in $EXTENSIONS_DIR/ (rename <skill>.md.example to <skill>.md to activate)"
  fi
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
  BACKFILL_TMP="$(mktemp)"; BACKFILL_ERR="$(mktemp)"
  trap 'rm -f "$BACKFILL_TMP" "$BACKFILL_ERR"' EXIT
  if ! jq -n --slurpfile ex "$EXAMPLE" --slurpfile cfg "$CONFIG" '
        ($cfg[0].devflow_review.agent_overrides? // {}) as $userao
        | ($ex[0] * $cfg[0])
        | if (.devflow_review | type) == "object" and (.devflow_review.agent_overrides | type) == "object" then
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
                   and (((.value.model | strings) // "") | startswith("claude-haiku-"))
                   and (.value | has("effort"))
                   and (($userao[$k] // {}) | (type == "object" and has("effort")) | not)
                then .value |= del(.effort) else . end)
          else . end' \
        > "$BACKFILL_TMP" 2>"$BACKFILL_ERR"; then
    # A genuine merge failure (odd jq build, OOM, corrupt template) is logged and
    # skipped — never masked as a silent no-op, and never aborts the scaffold. The
    # captured jq stderr is surfaced so the failure mode is actionable rather than
    # a fixed, ambiguous "(jq error)".
    bf_err="$(cat "$BACKFILL_ERR")"
    log "config-key backfill merge failed (jq error)${bf_err:+: $bf_err}; leaving $CONFIG unchanged."
  else
    # Rewrite only when the merge actually changed something; a jq normalization
    # failure leaves the config untouched (fail-safe) rather than overwriting
    # from a comparison we can't trust. See rewrite_config_if_changed.
    rewrite_config_if_changed "$CONFIG" "$BACKFILL_TMP" \
      "backfilled newly-added keys into $CONFIG from the example (your values and arrays kept)." \
      "could not compare the merged config against $CONFIG; leaving it unchanged."
  fi
  rm -f "$BACKFILL_TMP" "$BACKFILL_ERR"
  trap - EXIT
fi

# Repair model/effort combinations the model API rejects but the no-clobber
# backfill above structurally cannot fix. The shipped example once pinned the
# checklist-deduper to a Haiku id and carried an `effort` key on it; the example
# now defaults that override to Sonnet 4.6, but a key *removal* never propagates
# through the backfill — it only ADDS keys, never deletes (see the
# deletion-tracking note above). So an adopter who scaffolded earlier silently
# keeps `effort` on a Haiku override (their own deduper pin, or any other agent
# they pinned to Haiku), which the model API rejects (see the graft-guard above
# for the Haiku-rejects-effort / HTTP-400 rationale). This data-driven cleanup
# drops `effort` from any agent_overrides entry whose `model` is a Haiku id —
# narrow (only that combination), idempotent, and best-effort with the same
# mtime-churn guard as the backfill: an already-clean config is a quiet no-op.
# Lives here, not in the backfill, because it removes a key rather than adding
# one. (The backfill separately refuses to GRAFT the example's Sonnet-deduper
# effort onto a Haiku-pinned entry, so the two passes never churn against each
# other on a re-scaffold.)
if command -v jq >/dev/null 2>&1 && jq -e . "$CONFIG" >/dev/null 2>&1; then
  # Anti-silent-failure breadcrumb: if agent_overrides exists but is not an
  # object (hand-corrupted to an array/string/scalar), the cleanup filter below
  # still RUNS but no-ops via its `else .` arm (leaving the malformed value as-is).
  # Surface that we saw it, so the no-op is not an ambiguous "nothing to do" — and
  # word it as a no-op, NOT a "skip", so nobody mistakes it for the genuine
  # jq-missing skip below and adds a real `continue` that would strand the EXIT
  # trap set just after this probe. Capture the probe's exit status
  # (via `|| ao_rc=$?`, which keeps the failing assignment off `set -e`) instead
  # of folding a jq error into "null" with `|| printf 'null'`: when `devflow_review`
  # ITSELF is a non-object (e.g. a string), `.agent_overrides` indexing errors
  # (rc≠0) rather than yielding "null", and the old fold suppressed this very
  # breadcrumb — leaving only the generic "cleanup failed (jq error)" line below
  # to (mis)explain a corrupt config. Distinguish probe-error from genuinely-absent.
  ao_rc=0
  ao_type="$(jq -r '.devflow_review.agent_overrides | type' "$CONFIG" 2>/dev/null)" || ao_rc=$?
  if [ "$ao_rc" -ne 0 ]; then
    log "could not inspect .devflow_review.agent_overrides in $CONFIG (jq error — is devflow_review itself a non-object?); the Haiku effort-cleanup below will no-op."
  elif [ "$ao_type" != "object" ] && [ "$ao_type" != "null" ]; then
    log "agent_overrides is present but not an object ($ao_type); the Haiku effort-cleanup below will no-op (the non-object value is left untouched)."
  fi
  CLEANUP_TMP="$(mktemp)"; CLEANUP_ERR="$(mktemp)"
  trap 'rm -f "$CLEANUP_TMP" "$CLEANUP_ERR"' EXIT
  if ! jq '
        if (.devflow_review | type) == "object" and (.devflow_review.agent_overrides | type) == "object" then
          .devflow_review.agent_overrides |= with_entries(
            if (.value | type) == "object"
               and (((.value.model | strings) // "") | startswith("claude-haiku-"))
               and (.value | has("effort"))
            then .value |= del(.effort) else . end)
        else . end' "$CONFIG" > "$CLEANUP_TMP" 2>"$CLEANUP_ERR"; then
    # Surface the captured jq stderr so a genuine execution failure is actionable
    # rather than a fixed, ambiguous "(jq error)".
    cu_err="$(cat "$CLEANUP_ERR")"
    log "Haiku effort-cleanup failed (jq error)${cu_err:+: $cu_err}; leaving $CONFIG unchanged."
  else
    rewrite_config_if_changed "$CONFIG" "$CLEANUP_TMP" \
      "removed unsupported 'effort' from Haiku-pinned agent_overrides in $CONFIG (Claude Haiku rejects effort with HTTP 400)." \
      "could not compare the Haiku effort-cleanup against $CONFIG; leaving it unchanged."
  fi
  rm -f "$CLEANUP_TMP" "$CLEANUP_ERR"
  trap - EXIT
else
  # The backfill block above already logs the specific reason for the SAME guard
  # (jq missing / invalid JSON); cross-reference it here so this line reads as one
  # resolved cause rather than a second, distinct problem — while still emitting
  # its own breadcrumb so the Haiku migration is never silently dependent on the
  # backfill block for its skip notice.
  log "skipping Haiku effort-cleanup for the same reason as the backfill skip above (jq missing or $CONFIG not valid JSON)."
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
