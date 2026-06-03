#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# provision-auto-mode.sh — make the `auto` permission mode SELECTABLE in the
# Shift+Tab cycle by provisioning env.CLAUDE_CODE_ENABLE_AUTO_MODE="1" into the
# USER-scope ~/.claude/settings.json. The deferred-from-#88 half of the settings
# provisioning split (PR #89 shipped the project-scope marketplace half; this is
# issue #105).
#
# Selectable, NEVER on. It writes only the env var — never permissions.defaultMode —
# so plan/model/admin gates still apply and `auto` is a mode the user must actively
# select; nothing here turns it on.
#
# Why USER scope (not project): CLAUDE_CODE_ENABLE_AUTO_MODE is a permission-gating
# env var, and Claude Code filters those out of PROJECT scope — it is honored only
# from user scope (~/.claude/settings.json) or managed settings. Writing it into a
# repo's .claude/settings.json is a silent no-op, which is exactly why the project
# provisioner (scripts/provision-local-settings.sh) deliberately omits it.
#
# CONSENT: ~/.claude/settings.json affects ALL of the user's projects, not just this
# repo, so this helper never edits it without explicit consent. The DEFAULT (no
# --apply) prints the exact one-line setting for the user to add themselves and
# writes NOTHING. --apply performs the write, and /devflow:init passes it only after
# the user explicitly opts in.
#
# Merge discipline mirrors provision-local-settings.sh: additive, non-clobbering
# (the user's value wins at every depth — a deliberately-disabled "0" is PRESERVED,
# never flipped to "1"), idempotent, atomic (mktemp + same-dir mv), fail-closed (a
# malformed / wrong-shape existing file is left byte-for-byte unchanged with a
# specific breadcrumb and a non-zero exit, never partially overwritten).
#
# Usage: provision-auto-mode.sh [--apply] [TARGET_SETTINGS_FILE]
#   --apply               perform the user-scope write (the caller's confirmed
#                         consent). Without it, print the copy-paste line, exit 0,
#                         touch nothing.
#   TARGET_SETTINGS_FILE  settings.json to provision (default:
#                         ~/.claude/settings.json). The override exists for tests;
#                         production always targets user scope.
#
# Exit codes:
#   0  printed the copy-paste line (no --apply); or provisioned / already-complete
#      (--apply).
#   2  --apply but a precondition / I-O failure: the existing file is unreadable, is
#      not valid JSON, or is valid JSON of the wrong shape (a non-object root, or
#      `env` present as a non-object); or jq is missing; or HOME is unset with no
#      explicit target; or the settings dir / temp file / merged file could not be
#      created or written. In every exit-2 case the existing file is left
#      BYTE-FOR-BYTE UNCHANGED and a specific `devflow-automode:` breadcrumb names
#      the cause.
set -euo pipefail

log()  { printf 'devflow-automode: %s\n' "$1"; }
warn() { printf 'devflow-automode: %s\n' "$1" >&2; }

# ── Parse args: an optional --apply flag and at most one positional target. ──
# The positional is the settings file to provision (SETTINGS); production omits it
# and we default to user scope below.
APPLY=0
SETTINGS=""
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -*)      warn "unknown option: $arg"; exit 2 ;;
    *)       if [ -n "$SETTINGS" ]; then
               warn "unexpected extra argument: $arg"; exit 2
             fi
             SETTINGS="$arg" ;;
  esac
done

# Resolve the target. Default is user scope ($HOME/.claude/settings.json). In the
# no-consent path HOME-unset is non-fatal (we only need a label to display); in the
# --apply path it is a hard error (we cannot resolve where to write).
if [ -z "$SETTINGS" ]; then
  if [ -n "${HOME:-}" ]; then
    SETTINGS="$HOME/.claude/settings.json"
  elif [ "$APPLY" -eq 1 ]; then
    warn "cannot resolve ~/.claude/settings.json (HOME is unset); provisioned nothing."
    exit 2
  else
    SETTINGS="~/.claude/settings.json"   # display-only; no file is touched without --apply
  fi
fi

# The exact one-line setting we provision — printed verbatim in the no-consent path
# so the user can paste it into the `env` object of their user settings themselves.
SETTING_LINE='"env": { "CLAUDE_CODE_ENABLE_AUTO_MODE": "1" }'

# ── DEFAULT (no consent): surface the copy-paste line and write NOTHING. ──
if [ "$APPLY" -ne 1 ]; then
  log "auto mode is left unchanged. To make 'auto' SELECTABLE in the Shift+Tab"
  log "permission-mode cycle, add this to your user settings ($SETTINGS) yourself:"
  printf '    %s\n' "$SETTING_LINE"
  log "(selectable only — it is never turned on for you, and plan/model/admin gates still apply.)"
  log "Or, to have /devflow:init add it for you, re-run with explicit consent: provision-auto-mode.sh --apply"
  exit 0
fi

# ── --apply (consent confirmed by the caller): perform the user-scope merge. ──
SETTINGS_DIR="$(dirname "$SETTINGS")"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found; cannot provision $SETTINGS (install jq, then re-run /devflow:init)."
  exit 2
fi

# The DevFlow default as a JSON literal. The merge below is `$defaults * $existing`,
# so the user's value wins at every depth and only keys they have not set are filled.
# permissions.defaultMode is intentionally absent — auto stays selectable, never on.
DEFAULTS='{
  "env": { "CLAUDE_CODE_ENABLE_AUTO_MODE": "1" }
}'

# Resolve the existing settings into a JSON value to merge against.
#   - absent file                  -> start from {} (create it)
#   - empty / whitespace-only file -> benign, treat as {} (fill the key)
#   - non-empty, parses as JSON    -> use it verbatim
#   - non-empty, does NOT parse    -> MALFORMED: bail without touching the file
EXISTING='{}'
if [ -f "$SETTINGS" ]; then
  # Distinguish an unreadable file (perms) from invalid JSON so the breadcrumb names
  # the real cause rather than misdirecting the user to "fix the JSON".
  if [ ! -r "$SETTINGS" ]; then
    warn "existing $SETTINGS is not readable (check permissions); left it unchanged and provisioned nothing."
    exit 2
  fi
  if [ -s "$SETTINGS" ] && grep -q '[^[:space:]]' "$SETTINGS"; then
    if ! EXISTING="$(jq . "$SETTINGS" 2>/dev/null)"; then
      warn "existing $SETTINGS is not valid JSON; left it unchanged and provisioned nothing (fix or remove it, then re-run /devflow:init)."
      exit 2
    fi
  fi
fi

# Type-guard the shapes the deep-merge relies on. `jq .` above only proves the file
# PARSES; valid-but-corrupt shapes still slip through:
#   - a non-object ROOT (`[...]` or a bare scalar) — `$defaults * $existing` is a jq
#     error (object times array/scalar) that, under `set -euo pipefail`, would abort
#     with a raw jq message and escape the documented 0/2 contract with no breadcrumb;
#   - a non-object at an object-valued path the merge recurses THROUGH — here `env`,
#     where the user holds a non-object value. jq's `*` does not error there; it
#     silently keeps the user's value and drops DevFlow's whole subtree below it (the
#     auto-mode env var never lands), yet still exits 0 with a success breadcrumb.
# Derive the object-valued paths FROM $defaults (just `env` today, but this generalizes
# for free if defaults ever nests deeper — the same sweep provision-local-settings.sh
# uses) and flag any that $root holds as a non-object. A wrong-typed value at a genuine
# LEAF (CLAUDE_CODE_ENABLE_AUTO_MODE itself) is NOT an object-valued path, so it is a
# legitimate user-wins clobber and is never flagged. All flagged shapes are corrupt
# settings, treated exactly like the malformed-JSON case: a specific breadcrumb, exit 2,
# file left byte-for-byte unchanged.
# Capture with `if !` so a failure of the guard's OWN jq fails CLOSED — a bare
# assignment would mask the command-substitution exit status from `set -e` and sail
# past the `[ -n ]` check below as if the shape were validated.
if ! BAD_SHAPE="$(printf '%s' "$EXISTING" | jq -r --argjson defaults "$DEFAULTS" '
  . as $root
  | if ($root | type) != "object" then
      "the file is valid JSON but not a JSON object (\($root | type))"
    else
      ( [ ($defaults | paths) as $p
          | select(($defaults | getpath($p) | type) == "object") | $p ] as $objpaths
        | [ $objpaths[] | . as $p
            # Flag a path the user has PRESENT as a non-object (any type, including
            # null — jq merge treats a right-hand null as a winning value that
            # replaces the whole defaults subtree). Test presence via the parent
            # has() check, not getpath alone: getpath returns null for BOTH an absent
            # path and a present-null one, and an absent path is fine (the merge fills
            # it). A non-object parent is skipped here and flagged by its own
            # (shallower) object-path instead, so each corruption is named once.
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

# The merge cannot fail post-guard ($existing is a validated object whose `env` is
# object-or-absent, $defaults is a fixed valid object), but guard it anyway so an
# unanticipated jq failure fails CLOSED with a breadcrumb rather than a raw error.
if ! MERGED="$(jq -n --argjson defaults "$DEFAULTS" --argjson existing "$EXISTING" '$defaults * $existing')"; then
  warn "could not compute the provisioned settings for $SETTINGS (merge failed); left it unchanged."
  exit 2
fi

# Only write on a real change (idempotent — no mtime churn on a re-run, and the
# no-clobber "0" case lands here: the merge keeps the user's "0", so MERGED == EXISTING
# and we report "nothing changed" without a write). Compare canonical (sorted) forms so
# formatting differences never read as a change.
if [ "$(printf '%s' "$EXISTING" | jq -S .)" = "$(printf '%s' "$MERGED" | jq -S .)" ]; then
  log "$SETTINGS already has CLAUDE_CODE_ENABLE_AUTO_MODE set (your value is preserved); nothing changed."
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
# Guard the write so a failure (read-only FS, ENOSPC, an immutable/owned file) leaves a
# devflow-automode: breadcrumb + exit 2 rather than a raw shell/mv error. $SETTINGS is
# untouched until the mv (an atomic same-dir rename), so a failed write leaves the
# original intact.
if ! { printf '%s\n' "$MERGED" > "$TMP" && mv "$TMP" "$SETTINGS"; }; then
  warn "could not write $SETTINGS (check permissions and free space); left it unchanged."
  exit 2
fi
trap - EXIT

log "provisioned $SETTINGS: 'auto' is now SELECTABLE in the Shift+Tab permission-mode cycle (CLAUDE_CODE_ENABLE_AUTO_MODE=\"1\"). It is not turned on — select it yourself, and plan/model/admin gates still apply. Review the change before committing if this file is tracked."
exit 0
