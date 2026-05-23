#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Resolve whether a /devflow:implement trigger should run, and on which issue.
#
# devflow-implement.yml runs claude-code-action in AGENT mode with an explicit,
# synthesised `/devflow:implement <n>` prompt. Agent mode does NOT need the
# `@claude` phrase, so Anthropic's stock claude.yml (tag mode, keyed on
# `@claude`) never double-fires on a bare `/devflow:implement <n>` comment. The
# trade-off: agent mode runs for ANY actor, so this script is the cost/
# authorization gate. The only trigger is a bare command in a comment/review/
# issue body — there is no label path.
#
# Inputs (env):
#   ACTOR           triggering login (github.event.sender.login); a trailing
#                   `[bot]` suffix is tolerated.
#   ALLOWED_BOTS    comma-separated bare bot logins from config.
#   ALLOWED_USERS   comma-separated human logins ('*' = any collaborator).
#   REPO            owner/repo, for the collaborator-permission API call.
#   TRIGGER_TEXT    the comment / review / issue title+body that fired.
#   CONTEXT_NUMBER  the issue/PR number the event is attached to: the fallback
#                   target when TRIGGER_TEXT has no explicit number.
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
text="${TRIGGER_TEXT:-}"
context_number="${CONTEXT_NUMBER:-}"

# --- Authorization (cost control: agent mode runs for any actor) ------------
# Shared with resolve-command-trigger.sh — see scripts/authorize-actor.sh.
# shellcheck source=scripts/authorize-actor.sh
. "$(dirname "$0")/authorize-actor.sh"
authorize_actor   # sets $authorized and $deny_reason from ACTOR/ALLOWED_BOTS/REPO

# shellcheck disable=SC2154  # authorized/deny_reason are set by authorize_actor (sourced above)
if [ "$authorized" != "true" ]; then
  echo "::warning::/devflow:implement requested by '$actor' $deny_reason; skipping (cost control)." >&2
  emit should_run false
  emit number ""
  exit 0
fi

# --- Target number resolution -----------------------------------------------
# First explicit `/devflow:implement <n>` (optional leading #) wins; otherwise
# fall back to the issue/PR the event is attached to.
match="$(printf '%s' "$text" \
  | grep -oiE '/devflow:implement[[:space:]]+#?[0-9]+' | head -n1 || true)"
number="$(printf '%s' "$match" | grep -oE '[0-9]+' | head -n1 || true)"
[ -z "$number" ] && number="$context_number"

if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "::warning::Could not resolve an issue number for /devflow:implement; skipping." >&2
  emit should_run false
  emit number ""
  exit 0
fi

emit should_run true
emit number "$number"
