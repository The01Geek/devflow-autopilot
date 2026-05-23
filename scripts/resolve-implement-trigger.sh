#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Resolve whether a /devflow:implement trigger should run, and on which issue.
#
# claude-implement.yml runs claude-code-action in AGENT mode with an explicit,
# synthesised `/devflow:implement <n>` prompt. Agent mode does NOT need the
# `@claude` phrase, so a stock claude.yml (tag mode, keyed on `@claude`) never
# double-fires on a bare `/devflow:implement <n>` comment. The trade-off: agent
# mode runs for ANY actor, so this script is the cost/authorization gate.
#
# Inputs (env):
#   ACTOR           triggering login (github.event.sender.login); a trailing
#                   `[bot]` suffix is tolerated.
#   ALLOWED_BOTS    comma-separated bare bot logins from config.
#   REPO            owner/repo, for the collaborator-permission API call.
#   IS_LABEL_EVENT  "true" when the trigger is the implement label being added
#                   (no command text — use CONTEXT_NUMBER).
#   TRIGGER_TEXT    the comment / review / issue title+body that fired (empty
#                   on the label path).
#   CONTEXT_NUMBER  the issue/PR number the event is attached to: the fallback
#                   target when TRIGGER_TEXT has no explicit number, and the
#                   sole target on the label path.
#   GH_TOKEN        token for `gh api` (collaborator check), set by the caller.
#
# Output: two `key=value` lines on stdout (the caller appends them to
# $GITHUB_OUTPUT; tests assert them directly):
#   should_run=true|false
#   number=<n>|""
#
# should_run is true ONLY when the actor is authorized AND a number resolves.
# Fails CLOSED on any ambiguity. Diagnostics go to stderr as ::warning:: lines.

set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

actor="${ACTOR:-}"
allowed_bots="${ALLOWED_BOTS:-}"
repo="${REPO:-}"
is_label="${IS_LABEL_EVENT:-false}"
text="${TRIGGER_TEXT:-}"
context_number="${CONTEXT_NUMBER:-}"

# --- Authorization (cost control: agent mode runs for any actor) ------------
authorized=false
actor_bare="${actor%\[bot\]}"
IFS=',' read -ra bots <<< "$allowed_bots"
for b in "${bots[@]}"; do
  # Trim surrounding whitespace via parameter expansion, NOT `echo | xargs`:
  # xargs does shell word-splitting/quote processing, so a config value
  # containing a quote or backslash could be mangled — or make xargs exit
  # non-zero, which under `set -e` would abort this authorization loop hard
  # instead of failing closed.
  bt="${b#"${b%%[![:space:]]*}"}"   # strip leading whitespace
  bt="${bt%"${bt##*[![:space:]]}"}" # strip trailing whitespace
  if [ -n "$bt" ] && { [ "$bt" = "$actor" ] || [ "$bt" = "$actor_bare" ]; }; then
    authorized=true
  fi
done
deny_reason="is not an allowed bot or write/admin/maintain collaborator"
if [ "$authorized" != "true" ] && [ -n "$actor" ] && [ -n "$repo" ]; then
  # Distinguish a definitive "not a collaborator" (HTTP 404) from any other
  # lookup failure. The old `2>/dev/null || echo none` collapsed BOTH to
  # "none", so a rate-limit / 5xx / auth / network blip silently denied a
  # genuine write/admin user and mislabelled it a permission problem. Retry
  # once on a non-404 error before failing closed; on failure, surface the
  # actual gh error so the operator can tell a transient blip from a permanent
  # misconfiguration (missing gh, unset GH_TOKEN, 401/403 scope) rather than
  # being told to expect transience.
  err_file="$(mktemp)"
  perm=""
  last_err=""
  for attempt in 1 2; do
    if perm="$(gh api "repos/$repo/collaborators/$actor/permission" \
                 --jq '.permission' 2>"$err_file")"; then
      break
    fi
    if grep -q 'HTTP 404' "$err_file"; then
      perm="none"            # actor is genuinely not a collaborator
      break
    fi
    perm="__lookup_failed__"
    last_err="$(head -n1 "$err_file" 2>/dev/null || true)"
    [ "$attempt" = 1 ] && sleep "${RESOLVE_RETRY_DELAY:-2}"
  done
  rm -f "$err_file"
  case "$perm" in
    admin|write|maintain) authorized=true ;;
    __lookup_failed__)
      deny_reason="collaborator-permission lookup failed after retry; failing closed${last_err:+ (gh: $last_err)}" ;;
  esac
fi
if [ "$authorized" != "true" ]; then
  echo "::warning::/devflow:implement requested by '$actor' $deny_reason; skipping (cost control)." >&2
  emit should_run false
  emit number ""
  exit 0
fi

# --- Target number resolution -----------------------------------------------
number=""
if [ "$is_label" = "true" ]; then
  number="$context_number"
else
  # First explicit `/devflow:implement <n>` (optional leading #) wins.
  match="$(printf '%s' "$text" \
    | grep -oiE '/devflow:implement[[:space:]]+#?[0-9]+' | head -n1 || true)"
  number="$(printf '%s' "$match" | grep -oE '[0-9]+' | head -n1 || true)"
  # Otherwise fall back to the issue/PR the event is attached to.
  [ -z "$number" ] && number="$context_number"
fi

if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "::warning::Could not resolve an issue number for /devflow:implement; skipping." >&2
  emit should_run false
  emit number ""
  exit 0
fi

emit should_run true
emit number "$number"
