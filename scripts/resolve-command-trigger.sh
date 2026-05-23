#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Resolve whether a LIGHT /devflow:* command (review, review-and-fix,
# pr-description) should run, which one, and on which issue/PR number.
#
# devflow.yml's command path runs claude-code-action in AGENT mode with an
# explicit synthesised `/devflow:<cmd> <n>` prompt. Agent mode needs no
# `@claude` phrase, so this never collides with Anthropic's stock claude.yml
# (TAG mode, keyed on `@claude`). Agent mode runs for ANY actor, so this script
# is the cost/authorization gate — same contract as resolve-implement-trigger.sh.
#
# /devflow:implement is intentionally NOT handled here — it's the heavy path
# (devflow-implement.yml). The workflow `if:` already excludes it; we re-exclude
# defensively below.
#
# Inputs (env): ACTOR, ALLOWED_BOTS, ALLOWED_USERS, REPO, GH_TOKEN,
#               TRIGGER_TEXT, CONTEXT_NUMBER
# Output (stdout; caller appends to $GITHUB_OUTPUT, tests assert directly):
#   should_run=true|false
#   command=/devflow:<cmd> <n>|""
set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

text="${TRIGGER_TEXT:-}"
context_number="${CONTEXT_NUMBER:-}"

# --- Command detection (most specific first; review-and-fix contains review) -
cmd=""
if printf '%s' "$text" | grep -qiE '/devflow:review-and-fix'; then
  cmd="/devflow:review-and-fix"
elif printf '%s' "$text" | grep -qiE '/devflow:review'; then
  cmd="/devflow:review"
elif printf '%s' "$text" | grep -qiE '/devflow:pr-description'; then
  cmd="/devflow:pr-description"
fi

if [ -z "$cmd" ]; then
  echo "::notice::No light /devflow:* command in trigger text; nothing to dispatch." >&2
  emit should_run false
  emit command ""
  exit 0
fi

# --- Authorization (cost control: agent mode runs for any actor) ------------
# Shared with resolve-implement-trigger.sh — see scripts/authorize-actor.sh.
# shellcheck source=scripts/authorize-actor.sh
. "$(dirname "$0")/authorize-actor.sh"
authorize_actor

# shellcheck disable=SC2154  # authorized/deny_reason are set by authorize_actor (sourced above)
if [ "$authorized" != "true" ]; then
  echo "::warning::${cmd} requested by '${ACTOR:-}' $deny_reason; skipping (cost control)." >&2
  emit should_run false
  emit command ""
  exit 0
fi

# --- Target number resolution -----------------------------------------------
# First explicit `<cmd> <n>` (optional leading #) wins; else the event's number.
esc_cmd="$(printf '%s' "$cmd" | sed 's/[.[\*^$()+?{|]/\\&/g')"
match="$(printf '%s' "$text" \
  | grep -oiE "${esc_cmd}[[:space:]]+#?[0-9]+" | head -n1 || true)"
number="$(printf '%s' "$match" | grep -oE '[0-9]+' | head -n1 || true)"
[ -z "$number" ] && number="$context_number"

if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "::warning::Could not resolve an issue/PR number for ${cmd}; skipping." >&2
  emit should_run false
  emit command ""
  exit 0
fi

emit should_run true
emit command "$cmd $number"
