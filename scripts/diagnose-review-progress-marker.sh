#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# diagnose-review-progress-marker.sh REPO PR_NUMBER EXPECTED_MARKER
#
# Best-effort diagnosis for the dead-run review-progress flip (issue #1054).
# The flip remains authoritative and unchanged: this helper only explains why an
# exact-marker lookup may have missed. It prints exactly one outcome and always
# exits zero:
#
#   matched        an active bot-authored Reviewing comment has EXPECTED_MARKER
#   foreign        an active bot-authored Reviewing comment has another run key
#   absent         no active bot-authored Reviewing progress comment exists
#   unestablished  inputs, GitHub response, jq, or API access were unusable
#
# `matched` wins over `foreign` if both are present. Only callers decide how to
# surface the result; in particular, `foreign` is evidence of a possible marker
# mismatch, while `unestablished` must never be presented as one.

set -uo pipefail

REPO="${1:-}"
PR_NUMBER="${2:-}"
EXPECTED_MARKER="${3:-}"

emit_result() {
  case "$1" in
    foreign)
      echo "::warning::flip review-progress: possible review-progress marker mismatch; an active Reviewing comment exists under a foreign run key" >&2 ;;
    unestablished)
      echo "::notice::flip review-progress: could not establish whether a review-progress marker mismatch exists" >&2 ;;
  esac
  echo "$1"
  exit 0
}

emit_unestablished() { emit_result unestablished; }

case "$REPO" in
  */*) ;;
  *)
    echo "devflow review-progress diagnosis: repository key is empty or not owner/repo" >&2
    emit_unestablished ;;
esac
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "devflow review-progress diagnosis: PR number '$PR_NUMBER' is not numeric" >&2
    emit_unestablished ;;
esac
if [ -z "$EXPECTED_MARKER" ]; then
  echo "devflow review-progress diagnosis: expected marker is empty" >&2
  emit_unestablished
fi

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR=.
fi
if ! SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd)" || [ -z "$SCRIPT_DIR" ]; then
  echo "devflow review-progress diagnosis: helper directory could not be resolved" >&2
  emit_unestablished
fi

# Resolve both external tools through the repository's single-source resolvers.
# A partial deployment is an unestablished diagnosis, never a bare-tool guess.
# shellcheck source=../lib/resolve-gh.sh
if ! . "$SCRIPT_DIR/../lib/resolve-gh.sh" || ! type devflow_resolve_gh >/dev/null 2>&1; then
  echo "devflow review-progress diagnosis: resolve-gh.sh was unavailable" >&2
  emit_unestablished
fi
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"
# shellcheck source=../lib/resolve-jq.sh
if ! . "$SCRIPT_DIR/../lib/resolve-jq.sh" || [ -z "${DEVFLOW_JQ:-}" ]; then
  echo "devflow review-progress diagnosis: resolve-jq.sh was unavailable" >&2
  emit_unestablished
fi

COMMENTS_JSON="$("$DEVFLOW_GH" api --paginate "repos/$REPO/issues/$PR_NUMBER/comments" 2>/dev/null)"
GH_RC=$?
if [ "$GH_RC" -ne 0 ] || [ -z "$COMMENTS_JSON" ]; then
  echo "devflow review-progress diagnosis: comments query failed or returned an empty response for PR #$PR_NUMBER" >&2
  emit_unestablished
fi

DECISION="$("$DEVFLOW_JQ" -sr \
  --arg expected "$EXPECTED_MARKER" \
  --arg current '<!-- prflow:review-progress run=' \
  --arg superseded '<!-- devflow:review-progress run=' \
  --arg status '**Status:** 🚀 Reviewing' '
  def textbody:
    (.body // "") | if type == "string" then . else "" end;
  def candidate:
    ((.user.type // "") == "Bot")
    and (textbody | startswith($current) or startswith($superseded))
    and (textbody | contains($status));
  def owns($marker):
    (textbody == $marker) or (textbody | startswith($marker + "\n"));
  if any(.[]; type != "array") then error("not-array")
  else
    add
    | ([.[] | select(candidate) | select(owns($expected))] | length) as $matched
    | ([.[] | select(candidate) | select(owns($expected) | not)] | length) as $foreign
    | "\($matched) \($foreign)"
  end
  ' <<<"$COMMENTS_JSON" 2>/dev/null)"
JQ_RC=$?
if [ "$JQ_RC" -ne 0 ] || ! [[ "$DECISION" =~ ^[0-9]+\ [0-9]+$ ]]; then
  echo "devflow review-progress diagnosis: comments response could not be parsed as the expected array" >&2
  emit_unestablished
fi

MATCHED="${DECISION%% *}"
FOREIGN="${DECISION#* }"
if [ "$MATCHED" -gt 0 ]; then
  emit_result matched
elif [ "$FOREIGN" -gt 0 ]; then
  emit_result foreign
else
  emit_result absent
fi
