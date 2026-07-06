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

# --- Self-trigger guard (runs BEFORE detection / authorization) -------------
# Defense-in-depth mirrored from resolve-implement-trigger.sh: decline any body
# that carries a DevFlow self-comment marker, so DevFlow's own marker-tagged
# comments (the review engine's run-keyed live progress comment, or an implement
# workpad) can never re-enter the gate — regardless of who authored them or what
# phrase they quote. The anchoring below is the authoritative gate for quoted
# prose; this guard cheaply catches DevFlow's own progress comment (whose
# narrative naturally quotes `/devflow:review`).
#
# The effective markers default to their built-in values (the run-keyed
# review-progress marker PREFIX `<!-- devflow:review-progress`, matching
# scripts/derive-review-verdict.sh's `<!-- devflow:review-progress run=<id>- -->`
# shape, and the workpad marker `<!-- devflow:workpad -->`, matching
# scripts/workpad.py's own fallback), so the guard protects a repo with no extra
# workflow wiring. Each is a literal substring match (`case`, not a regex), so a
# marker customized with regex-special characters still matches literally and a
# marker quoted/embedded anywhere in the body is still caught.
review_progress_marker="${SELF_REVIEW_PROGRESS_MARKER:-<!-- devflow:review-progress}"
workpad_marker="${SELF_WORKPAD_MARKER:-<!-- devflow:workpad -->}"
for marker in "$review_progress_marker" "$workpad_marker"; do
  [ -n "$marker" ] || continue
  case "$text" in
    *"$marker"*)
      echo "::warning::light /devflow:* trigger came from a Devflow-authored comment (self-comment marker '$marker' present); skipping (self-trigger guard)." >&2
      emit should_run false
      emit command ""
      exit 0
      ;;
  esac
done

# --- Command detection via the shared standalone-command detector -----------
# The detector is the single markdown-aware, anchored, fence-/indent-aware line
# scanner (scripts/detect-standalone-command.sh); the review_dedupe job in
# devflow.yml routes through the SAME script, so the trigger gate and the dedupe
# matcher cannot drift. It fires only on a standalone command in ordinary
# comment text (most-specific-first: review-and-fix outranks review), declining
# a command that is merely quoted in prose, blockquoted, indented as code, or
# inside a fenced block — so a non-invoking mention in any comment/review body
# is declined regardless of who authored it (this covers the reported PR-review
# vector). Invoked via `bash` so a vendored copy that lost its executable bit
# still runs (same robustness rationale as devflow.yml's `bash "$RESOLVER"`).
det_out="$(printf '%s' "$text" | bash "$(dirname "$0")/detect-standalone-command.sh")"
cmd="$(printf '%s\n' "$det_out" | sed -n 's/^command=//p')"
det_number="$(printf '%s\n' "$det_out" | sed -n 's/^number=//p')"

if [ -z "$cmd" ]; then
  echo "::warning::No STANDALONE light /devflow:* command in trigger text (a command merely quoted in prose, blockquoted, indented, or fenced does not trigger); nothing to dispatch." >&2
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
# The detector already returned the explicit number on the matched standalone
# command line (optional leading #), if any; else fall back to the event's
# context number.
number="$det_number"
[ -z "$number" ] && number="$context_number"

if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "::warning::Could not resolve an issue/PR number for ${cmd}; skipping." >&2
  emit should_run false
  emit command ""
  exit 0
fi

emit should_run true
emit command "$cmd $number"
