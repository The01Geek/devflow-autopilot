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
# authorization gate. The only trigger is a bare command in a real issue comment
# — never an issue description body, a PR comment, or a review (issues-only; see
# the IS_PULL_REQUEST guard below) — and there is no label path.
#
# Inputs (env):
#   ACTOR           triggering login (github.event.sender.login); a trailing
#                   `[bot]` suffix is tolerated.
#   ALLOWED_BOTS    comma-separated bare bot logins from config.
#   ALLOWED_USERS   comma-separated human logins ('*' = any collaborator).
#   REPO            owner/repo, for the collaborator-permission API call.
#   TRIGGER_TEXT    the issue-comment body that fired (never a description).
#   CONTEXT_NUMBER  the issue number the event is attached to: the fallback
#                   target when TRIGGER_TEXT has no explicit number.
#   SELF_COMMENT_MARKER  the repo's effective workpad marker. When TRIGGER_TEXT
#                   contains it (literal substring), the comment is one DevFlow
#                   posted itself (the workpad), so we decline — a self-trigger
#                   guard. Defaults to '<!-- devflow:workpad -->' when unset/empty
#                   (matching scripts/workpad.py's own fallback).
#   IS_PULL_REQUEST 'true' when the triggering thread is a pull request (the
#                   caller wires it from `github.event.issue.pull_request != null`).
#                   /devflow:implement is issue-only, so we decline on a PR — a
#                   resolver-level backstop for the gate `if:`'s PR filter. Any
#                   other value (including unset/empty) is treated as not-a-PR.
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
# Effective workpad marker; defaults to workpad.py's own fallback so the guard
# protects repos with no config just the same.
marker="${SELF_COMMENT_MARKER:-<!-- devflow:workpad -->}"
# Pull-request context signal; anything other than the literal 'true' (including
# unset/empty) is treated as an issue thread, so a repo that doesn't wire it
# behaves exactly as before.
is_pull_request="${IS_PULL_REQUEST:-}"

# --- Self-trigger guard (runs BEFORE authorization / number resolution) -----
# DevFlow's own workpad comment quotes the literal phrase `/devflow:implement`
# (e.g. the "/devflow:implement run started" note) and carries no `@claude`, so
# it would otherwise re-enter the gate and fire a duplicate run on its own
# thread. The workpad always begins with the marker (workpad.py matches it with
# startswith); here we deliberately decline any comment that *contains* the
# marker anywhere — a broader check, so a quoted/embedded marker is still caught
# — regardless of actor (an allowed bot posts the workpad) or which phrase it
# quotes. Substring match — not a regex — so a customized marker with
# regex-special chars matches literally.
if [ -n "$marker" ]; then
  case "$text" in
    *"$marker"*)
      echo "::warning::/devflow:implement trigger came from a Devflow-authored comment (workpad marker present); skipping (self-trigger guard)." >&2
      emit should_run false
      emit number ""
      exit 0
      ;;
  esac
fi

# --- Pull-request-context guard (runs BEFORE authorization / number resolution)
# In GitHub's API a PR comment IS an issue_comment, so a comment on a pull
# request would otherwise fall back to the PR number and start a spurious run
# (e.g. the weekly audit-report comment, which quotes the literal phrase
# `/devflow:implement` in prose, re-entering the gate on the state PR).
# /devflow:implement is issue-only. The gate `if:` already filters PR comments
# (`github.event.issue.pull_request == null`); this is the fail-closed resolver
# backstop, deliberately placed before authorization and number resolution so a
# PR comment is declined regardless of who sent it or whether it carries an
# explicit number. Mirrors the self-trigger guard's structure above.
if [ "$is_pull_request" = "true" ]; then
  echo "::warning::/devflow:implement triggered from a pull-request comment; it runs on issues only — skipping (pull-request-context guard)." >&2
  emit should_run false
  emit number ""
  exit 0
fi

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
