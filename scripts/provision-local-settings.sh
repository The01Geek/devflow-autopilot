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
# It deep-merges the DevFlow marketplace registration into the project settings,
# additively and WITHOUT clobbering any value the user already set:
#   - extraKnownMarketplaces["devflow-marketplace"]  (a github source for
#       The01Geek/devflow-autopilot + autoUpdate:true) and
#       enabledPlugins["devflow@devflow-marketplace"]=true, so Claude Code keeps
#       the DevFlow plugin updated.
#
# NOTE — selectable auto mode is NOT provisioned here. CLAUDE_CODE_ENABLE_AUTO_MODE
# is a permission-gating env var, and Claude Code filters those out of PROJECT
# scope: it is honored only from user scope (~/.claude/settings.json) or managed
# settings (see code.claude.com/docs/en/permission-modes and .../settings). Writing
# it into the project .claude/settings.json is a silent no-op, so it is deliberately
# omitted here; that capability lives in the dedicated, consent-gated user-scope
# provisioner scripts/provision-auto-mode.sh (issue #105).
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
#   2  any precondition or I/O failure — the existing .claude/settings.json is
#      unreadable, is not valid JSON, or is valid JSON of the wrong shape (a
#      non-object root, or a DevFlow object-valued path present as a non-object);
#      or jq is missing; or the settings dir / temp file could not be created or
#      the merged file could not be written. In every exit-2 case the existing
#      file is left BYTE-FOR-BYTE UNCHANGED and a specific `devflow-settings:`
#      breadcrumb names the cause.
set -euo pipefail

# jq binary: resolved once via the shared execution-verified resolver
# (lib/resolve-bin.sh, issue #247); an explicit DEVFLOW_JQ still wins, so test
# stubs and the Windows escape hatch are honored.
# Best-effort: when the resolver is not beside this script (a copied/vendored
# deployment), fall back to bare `jq` with a breadcrumb rather than aborting
# under the caller's set -e.
_DEVFLOW_RESOLVE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-bin.sh"
if [ -f "$_DEVFLOW_RESOLVE_BIN" ]; then
  # shellcheck source=../lib/resolve-bin.sh
  . "$_DEVFLOW_RESOLVE_BIN"
  : "${DEVFLOW_JQ:=$(devflow_resolve_bin jq)}"
else
  echo "devflow: lib/resolve-bin.sh not found beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2
  : "${DEVFLOW_JQ:=jq}"
fi

log()  { printf 'devflow-settings: %s\n' "$1"; }
warn() { printf 'devflow-settings: %s\n' "$1" >&2; }

TARGET_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SETTINGS_DIR="$TARGET_ROOT/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"

if ! "$DEVFLOW_JQ" --version >/dev/null 2>&1; then
  warn "no usable jq (missing or not executable); cannot provision $SETTINGS (install jq, or set DEVFLOW_JQ to a working jq/jq.exe, then re-run /devflow:init)."
  exit 2
fi

# The DevFlow defaults as a JSON literal. The merge below is `$defaults *
# $existing`, so the user's value wins at every depth and only keys they have
# not set are filled. permissions.defaultMode is intentionally absent, and no
# env var is written — see the auto-mode NOTE in the header.
DEFAULTS='{
  "extraKnownMarketplaces": {
    "devflow-marketplace": {
      "source": { "source": "github", "repo": "The01Geek/devflow-autopilot" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "devflow@devflow-marketplace": true }
}'

# Resolve the existing settings into a JSON value to merge against.
#   - absent file                  -> start from {} (create it)
#   - empty / whitespace-only file -> benign, treat as {} (fill the keys)
#   - non-empty, parses as JSON    -> use it verbatim
#   - non-empty, does NOT parse    -> MALFORMED: bail without touching the file
EXISTING='{}'
if [ -f "$SETTINGS" ]; then
  # Distinguish an unreadable file (perms) from invalid JSON so the breadcrumb
  # names the real cause rather than misdirecting the user to "fix the JSON".
  if [ ! -r "$SETTINGS" ]; then
    warn "existing $SETTINGS is not readable (check permissions); left it unchanged and provisioned nothing."
    exit 2
  fi
  if [ -s "$SETTINGS" ] && grep -q '[^[:space:]]' "$SETTINGS"; then
    if ! EXISTING="$("$DEVFLOW_JQ" . "$SETTINGS" 2>/dev/null)"; then
      warn "existing $SETTINGS is not valid JSON; left it unchanged and provisioned nothing (fix or remove it, then re-run /devflow:init)."
      exit 2
    fi
  fi
fi

# Type-guard the shapes the deep-merge relies on. `jq .` above only proves the
# file PARSES; valid-but-corrupt shapes still slip through:
#   - a non-object ROOT (`[...]` or a bare scalar) — `$defaults * $existing` is a
#     jq error (object times array/scalar) that, under `set -euo pipefail`, aborts
#     the script with a raw jq message and exit 5, escaping the documented 0/2
#     contract with no breadcrumb;
#   - a non-object at any path the merge must recurse THROUGH — every object-valued
#     path in $defaults (extraKnownMarketplaces, its devflow-marketplace entry, that
#     entry's source object, enabledPlugins) — where the user holds a non-object
#     value. jq's `*` does not error there; it silently keeps the user's value and
#     drops DevFlow's whole subtree below it (e.g. a string at devflow-marketplace
#     drops the marketplace source + autoUpdate, so the plugin never auto-updates),
#     yet still exits 0 with a success breadcrumb.
# To catch EVERY level in one sweep (rather than enumerating them by hand and
# rediscovering the next level each review), derive the object-valued paths FROM
# $defaults and flag any that $root holds as a non-object. A wrong-typed value at a
# genuine LEAF (autoUpdate, the enable flag, source.repo) is NOT an
# object-valued path, so it is a legitimate user-wins clobber and is never flagged.
# All flagged shapes are corrupt settings, treated exactly like the malformed-JSON
# case above: a specific breadcrumb, exit 2, file left byte-for-byte unchanged
# (nothing written yet). Mirrors scaffold-config.sh, which type-checks a container
# is an object before recursing.
# Capture with `if !` so a failure of the guard's OWN jq fails CLOSED. A bare
# `BAD_SHAPE="$(…)"` assignment masks the command-substitution exit status from
# `set -e`, so a jq error inside the probe would leave BAD_SHAPE empty and sail
# past the `[ -n ]` check below as if the shape were validated — silently
# defeating the very guard meant to prevent a bad merge. Treat a probe failure as
# corrupt input (exit 2, file untouched).
if ! BAD_SHAPE="$(printf '%s' "$EXISTING" | "$DEVFLOW_JQ" -r --argjson defaults "$DEFAULTS" '
  . as $root
  | if ($root | type) != "object" then
      "the file is valid JSON but not a JSON object (\($root | type))"
    else
      ( [ ($defaults | paths) as $p
          | select(($defaults | getpath($p) | type) == "object") | $p ] as $objpaths
        | [ $objpaths[] | . as $p
            # Flag a path the user has PRESENT as a non-object (any type, including
            # null — jq merge treats a right-hand null as a winning value that
            # replaces the whole defaults subtree, so a present null silently drops
            # the DevFlow setting just like a string would). Test presence via the
            # parent has() check, not getpath alone: getpath returns null for BOTH an
            # absent path and a present-null one, and an absent path is fine (the
            # merge fills it). A non-object parent is skipped here and flagged by its
            # own (shallower) object-path instead, so each corruption is named once.
            | ($root | try getpath($p[0:-1]) catch null) as $parent
            | select(($parent | type) == "object" and ($parent | has($p[-1]))
                     and (($parent[$p[-1]]) | type) != "object")
            | "the \($p | join(".")) path is present but not a JSON object (\(($parent[$p[-1]]) | type))" ]
        | join("; ") )
    end')"; then
  warn "existing $SETTINGS could not be validated for provisioning (the settings-shape check failed); left it unchanged and provisioned nothing."
  exit 2
fi
if [ -n "$BAD_SHAPE" ]; then
  warn "existing $SETTINGS is malformed for provisioning ($BAD_SHAPE); left it unchanged and provisioned nothing (fix or remove it, then re-run /devflow:init)."
  exit 2
fi

# The merge cannot fail post-guard ($existing is a validated object whose every
# DevFlow object-path is object-or-absent, $defaults is a fixed valid object, so
# `*` always succeeds), but guard it anyway so an unanticipated jq failure
# (OOM, a broken build) fails CLOSED with a breadcrumb rather than a raw error.
if ! MERGED="$("$DEVFLOW_JQ" -n --argjson defaults "$DEFAULTS" --argjson existing "$EXISTING" '$defaults * $existing')"; then
  warn "could not compute the provisioned settings for $SETTINGS (merge failed); left it unchanged."
  exit 2
fi

# Only write on a real change (idempotent — no mtime churn on a re-run). Compare
# canonical (sorted) forms so formatting differences never read as a change.
if [ "$(printf '%s' "$EXISTING" | "$DEVFLOW_JQ" -S .)" = "$(printf '%s' "$MERGED" | "$DEVFLOW_JQ" -S .)" ]; then
  log ".claude/settings.json already has the DevFlow keys; nothing changed."
  exit 0
fi

mkdir -p "$SETTINGS_DIR" || {
  warn "could not create $SETTINGS_DIR; left $SETTINGS unchanged."
  exit 2
}
TMP="$(mktemp "$SETTINGS_DIR/.settings.json.XXXXXX")" || {
  warn "could not create a temp file in $SETTINGS_DIR; left $SETTINGS unchanged."
  exit 2
}
trap 'rm -f "$TMP"' EXIT
# Guard the write so a failure (read-only FS, ENOSPC, an immutable/owned file)
# leaves a devflow-settings: breadcrumb + exit 2 rather than a raw shell/mv error
# that escapes the documented 0/2 contract. $SETTINGS is untouched until the mv
# (an atomic same-dir rename), so a failed write leaves the original intact.
if ! { printf '%s\n' "$MERGED" > "$TMP" && mv "$TMP" "$SETTINGS"; }; then
  warn "could not write $SETTINGS (check permissions and free space); left it unchanged."
  exit 2
fi
trap - EXIT

# Friendly labels for the DevFlow marker keys the merge actually landed, derived
# from the EXISTING->MERGED delta (a leaf differs) so the breadcrumb can never
# claim a key the merge did not write. The top-level containers are guaranteed
# object-or-absent by the type-guard above, so these two-level getpath probes
# never index a non-object. We reach here only past the "nothing changed"
# early-exit, so at least one leaf differs.
# Capture the delta with `if !` so a failure of this jq fails CLOSED: it runs via
# command substitution (not the old `done < <(jq …)` process substitution, whose
# exit status `set -e` cannot observe), so a jq hiccup here degrades to the generic
# success message with a warning rather than silently. The write already succeeded
# (atomic mv above), so a delta-probe failure cannot corrupt provisioning.
added_raw=""
if ! added_raw="$("$DEVFLOW_JQ" -nr --argjson e "$EXISTING" --argjson m "$MERGED" '
  [ {l: "extraKnownMarketplaces[devflow-marketplace]", p: ["extraKnownMarketplaces", "devflow-marketplace"]},
    {l: "enabledPlugins[devflow@devflow-marketplace]",  p: ["enabledPlugins", "devflow@devflow-marketplace"]} ]
  | map(select(($e | getpath(.p)) != ($m | getpath(.p))) | .l) | .[]')"; then
  warn "provisioned $SETTINGS but could not summarize which keys changed (delta probe failed)."
  added_raw=""
fi
added=()
while IFS= read -r label; do
  [ -n "$label" ] && added+=("$label")
done <<< "$added_raw"

if [ "${#added[@]}" -gt 0 ]; then
  joined="$(printf '%s, ' "${added[@]}")"; joined="${joined%, }"
  log "provisioned $SETTINGS (added: $joined): the DevFlow marketplace is now registered and auto-updating. Review the change before committing."
else
  log "provisioned $SETTINGS: the DevFlow marketplace is now registered and auto-updating. Review the change before committing."
fi
