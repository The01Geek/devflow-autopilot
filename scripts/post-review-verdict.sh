#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# post-review-verdict.sh PR_NUMBER EVENT BODY_FILE — post a PRFlow Review verdict
# as a formal GitHub Pull Request review, printing exactly one closed-vocabulary
# outcome line the caller routes on (issue #1059).
#
# WHY A HELPER, not an inline `gh pr review` fence (issues #1059, #857): Phase 4.4
# used to map the verdict to an unwrapped `gh pr review --request-changes|--comment|
# --approve` porcelain invocation whose outcome the review engine could observe only
# in its own per-turn transcript — a channel that reaches no durable artifact on the
# cloud tier. When that post failed on an APPROVE (observed on PR #1058), the approval
# survived only as prose in a `gh pr comment`, the PR stayed wedged at
# reviewDecision=CHANGES_REQUESTED, and NOTHING durable recorded that the post had
# failed. Moving the post into this helper — modelled on scripts/seed-review-progress.sh
# — gives it a closed outcome vocabulary the caller branches on, an error line captured
# from the failed API call, and a single-statement, leading-token shape the cloud matcher
# permits, so lib/test/run.sh can drive every path as ordinary shell.
#
# It posts through `gh api` REST (POST repos/{owner}/{repo}/pulls/{n}/reviews) rather than
# `gh pr review` porcelain, matching CLAUDE.md's rule for GitHub writes — the {owner}/{repo}
# placeholders are the ones `gh` fills from the git remote, NEVER an interpolated
# $GITHUB_REPOSITORY (which is empty outside Actions and collapses the path to `repos//…`).
# This is convention alignment, NOT a claim that porcelain caused the observed failure,
# which was never established (issue #1059's root-cause investigation is explicit on this).
# The body is passed as a FILE PATH, not an inline string, which removes the shell-quoting
# hazard for a report containing backticks, `$(`, and literal double quotes: the file's
# bytes are read verbatim by jq --rawfile and sent as the review body unmodified.
#
# CONTRACT — exactly one outcome line per reachable path. The vocabulary is closed and
# complete by construction (these five, and no other), and there is NO silent path:
#
#   stdout                     exit  meaning
#   POSTED <event>             0     the review was created for <event>
#   FAILED <one-line error>    1     the API call was issued and refused; the captured
#                                    error text (collapsed to one line) follows
#   SKIP not-numeric           3     the PR number is empty or non-numeric; no request issued
#   SKIP unknown-event         3     the event is not one of APPROVE / REQUEST_CHANGES /
#                                    COMMENT (INCLUDING the empty string); no request issued
#   SKIP body-file-unreadable  3     the body-file argument is absent or unreadable; no
#                                    request issued
#
# WHAT SILENCE MEANS. Printing NOTHING is not one of the outcomes above: a helper that
# emits no line at all was refused by the harness/permission matcher before it ran. A
# caller reads that silence as "route to the fallback arm" (post the full report as a
# plain comment and record that the formal review could not be posted) — NEVER as
# authorization to treat the review as posted. Likewise the caller must never read a
# `FAILED`/`SKIP …` line as a posted review: only `POSTED <event>` (exit 0) means the
# formal review exists.
#
# WHY the empty/absent event is refused rather than sent (issue #1059). GitHub's REST docs
# for "Create a review for a pull request" state that leaving `event` blank sets the review
# to PENDING — an unsubmitted draft nobody submits, i.e. a silent non-post. So an event
# outside the three accepted values, the empty string included, takes SKIP unknown-event
# and issues no request; the helper never sends a request whose `event` field is empty.
#
# Exit codes here are this helper's OWN contract and align with neither sibling: 0 for the
# single success token, 1 for an issued-and-refused API call, 3 for every "declined to try"
# SKIP. Read it as a separate contract from seed-review-progress.sh / dismiss-stale-rejections.sh.
#
# Requires: gh (authenticated, resolved through lib/resolve-gh.sh) and jq (through
# lib/resolve-jq.sh). $DEVFLOW_GH / $DEVFLOW_JQ override the binaries for tests, the same
# seam the rest of devflow uses.
#
# Usage: post-review-verdict.sh PR_NUMBER EVENT BODY_FILE
set -uo pipefail
# gh + jq: resolved once via the single-source execution-verified resolvers; an explicit
# DEVFLOW_GH/DEVFLOW_JQ still wins, so test stubs are untouched. Both sources are guarded
# so a partially-copied deploy degrades to the bare binary with a breadcrumb rather than
# aborting under `set -u`. resolve-gh.sh exposes a function; resolve-jq.sh assigns
# DEVFLOW_JQ on source (no function to call).
_PRV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-gh.sh
. "$_PRV_DIR/../lib/resolve-gh.sh" \
  || { echo "devflow post-verdict: resolve-gh.sh could not be sourced — using bare 'gh' (set DEVFLOW_GH to override)" >&2; devflow_resolve_gh() { echo "${DEVFLOW_GH:-gh}"; }; }
# shellcheck source=../lib/resolve-jq.sh
. "$_PRV_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow post-verdict: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"
: "${DEVFLOW_JQ:=jq}"

PR_NUMBER="${1:-}"
EVENT="${2:-}"
BODY_FILE="${3:-}"

# (1) Refuse a non-numeric PR number before any request. The `case` glob is a bash
# builtin (no PATH tool), so the screen holds on a stripped-down host.
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "devflow post-verdict: PR number '$PR_NUMBER' is not numeric — refusing the review post (no request issued)" >&2
    echo "SKIP not-numeric"
    exit 3 ;;
esac

# (2) Accept ONLY the three documented review events. The empty string and any other
# value take this arm, so no PENDING-draft request can ever be issued.
case "$EVENT" in
  APPROVE|REQUEST_CHANGES|COMMENT) ;;
  *)
    echo "devflow post-verdict: review event '$EVENT' is not one of APPROVE / REQUEST_CHANGES / COMMENT — refusing the post (a blank/unknown event would create an unsubmitted PENDING review)" >&2
    echo "SKIP unknown-event"
    exit 3 ;;
esac

# (3) The body file must be a readable file. An empty-but-readable body is allowed (it
# posts an empty review body); only absent/unreadable refuses.
if [ ! -r "$BODY_FILE" ] || [ ! -f "$BODY_FILE" ]; then
  echo "devflow post-verdict: body file '$BODY_FILE' is absent or unreadable — refusing the post (no request issued)" >&2
  echo "SKIP body-file-unreadable"
  exit 3
fi

# Build the JSON request body with jq --rawfile so arbitrary body bytes (backticks,
# `$(`, literal quotes, newlines) reach the API unmangled, then issue exactly one POST.
# Capture the API call's stderr (never /dev/null) so a FAILED outcome carries its cause;
# discard stdout. The whole pipeline runs under `set -o pipefail`, so a jq failure or a
# gh failure both surface as a non-zero pipeline status routed to the FAILED arm.
if ERR="$("$DEVFLOW_JQ" -n --arg event "$EVENT" --rawfile body "$BODY_FILE" '{event:$event, body:$body}' \
          | "$DEVFLOW_GH" api -X POST "repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews" --input - 2>&1 1>/dev/null)"; then
  echo "POSTED $EVENT"
  exit 0
fi
# Collapse the captured error to a single line with pure parameter expansion — an EMITTED
# value must not be routed through a non-preflight PATH tool (tr/sed), which would come
# back empty on a host that lacks it. Newlines and carriage returns become spaces.
ERR="${ERR//$'\n'/ }"
ERR="${ERR//$'\r'/ }"
[ -n "$ERR" ] || ERR="(no error output)"
echo "FAILED $ERR"
exit 1
