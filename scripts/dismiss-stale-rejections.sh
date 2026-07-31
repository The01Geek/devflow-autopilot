#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Dismiss Devflow Review's own still-outstanding CHANGES_REQUESTED reviews.
#
# Called after a Devflow Review APPROVE verdict to clear a prior REJECT's
# `--request-changes` review. GitHub keeps that review the PR's effective
# `reviewDecision` until it is *dismissed*: a later APPROVE-with-notes is a
# `--comment` review (never supersedes) and the REJECT may be a different
# bot identity (auto path = github-actions[bot], manual @claude = another),
# so no later review clears it. Without an explicit dismissal the PR is
# wedged at reviewDecision=CHANGES_REQUESTED despite a green required check.
#
# Scope: ONLY reviews whose body is a Devflow Review formal verdict are
# dismissed. Two body shapes are matched:
#   1. New stub format (post-#135 consolidation): the formal review body
#      starts with `## Verdict: REJECT` — the full Phase 4.1 report lives
#      in the progress comment, not the review body, so the review carries
#      only a short verdict stub.
#   2. Legacy format (pre-#135): the formal review body starts with
#      `# Review Report` (kept for backward compatibility with any
#      pre-consolidation reviews still outstanding on long-lived PRs).
# A human reviewer's `--request-changes` carries neither marker and is left
# untouched — an automated APPROVE must never silently clear a human's
# block.
#
# Commit scoping (issue #1029) — the second half of "stale". The body marker
# says WHOSE review it is; it says nothing about whether the review is
# SUPERSEDED, and this script only ever has licence to clear a superseded one.
# The reviews API is HEAD-scoped: every review carries the `commit_id` it was
# recorded against. A CHANGES_REQUESTED review whose `commit_id` equals the
# PR's CURRENT head is by definition not superseded — dismissing it discards a
# live merge-blocking finding about the very commit the caller just approved.
# That is reachable, not theoretical: two review passes 71s apart both judged
# commit f798f2f6 of PR #999 and disagreed, and the later APPROVE-with-notes
# was instructed to dismiss the earlier REJECT (it survived only because that
# REJECT's body matched neither prefix above — a producer accident, not a
# guard). So every candidate must be shown stale before it is dismissed:
#   - `commit_id` != current head .. genuinely superseded .. DISMISS
#   - `commit_id` == current head .. not superseded ......... REFUSE
#   - `commit_id` absent/empty .... staleness unprovable .... REFUSE
# The absent-comparand arm is the fail-CLOSED direction on purpose: a guard
# that treats an unreadable comparand as "not equal" fails open exactly where
# it claims to fail closed.
#
# The caller decides WHEN to run this (APPROVE only — never on REJECT, the
# changes-request must stand). This script does not inspect the verdict.
#
# Usage: dismiss-stale-rejections.sh PR_NUMBER [REPO]
#   PR_NUMBER  the pull request number
#   REPO       owner/name; defaults to `$DEVFLOW_GH repo view`'s nameWithOwner
#
# Re-run safe: a dismissed review's state becomes DISMISSED so it no longer
# matches the filter; re-running this script after a successful pass is a
# genuine no-op. (It still dismisses any NEW Devflow-report CHANGES_REQUESTED
# that appeared since ON A SUPERSEDED COMMIT — that is the intended behavior,
# not non-idempotency. One that appeared on the current head is refused, per
# the commit scoping above.)
# Best-effort per review: a failed dismissal is logged and the rest still
# run; the verdict never depends on this housekeeping.
#
# Requires: gh (authenticated), jq. Needs pull-requests:write — the
# dismissals API can dismiss ANY reviewer's review (required for the
# cross-identity case). $DEVFLOW_GH overrides the `gh` binary for tests
# (same seam as the rest of devflow; see lib/fetch-pr-context.sh).
#
# Exit codes:
#   0  all matching reviews dismissed, or none were outstanding (no-op)
#   1  a query failed (the review list, or the current-head read), or one or
#      more dismissals failed (caller may warn; never fatal there)
#   2  bad arguments
#   3  nothing failed, but at least one Devflow-report CHANGES_REQUESTED was
#      left outstanding because it could not be shown superseded (issue
#      #1029). Distinct from 0 on purpose: "refused" is not "there was
#      nothing to do", and collapsing an unestablished outcome onto the
#      success value is what makes a wedged PR look like a clean no-op.
#      A real failure outranks a refusal, so 1 wins when both occur. The
#      caller's existing branch — non-zero means say the PR stays blocked
#      until dismissed manually — is the correct human message here too.

set -euo pipefail
# gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins, so test stubs are untouched.
# shellcheck source=../lib/resolve-gh.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "usage: dismiss-stale-rejections.sh PR_NUMBER [REPO]" >&2
  exit 2
fi
PR="$1"
REPO="${2:-$("$DEVFLOW_GH" repo view --json nameWithOwner --jq .nameWithOwner)}"

# One paginated call (consistent with claude.yml Signal 1) so the loop runs
# in THIS shell, not a pipe subshell: a per-review failure flag survives, no
# recount round-trip is needed, and a list-call failure (exit 1, nothing
# dismissed) stays distinct from a clean no-op (no matching reviews). The
# body-marker filter is what scopes this to Devflow's own reviews; each row
# also carries the review's `commit_id`, the comparand the staleness test
# below needs (`// ""` so an absent/null one arrives as an empty field rather
# than aborting the filter).
if ! ROWS=$("$DEVFLOW_GH" api --paginate "repos/$REPO/pulls/$PR/reviews?per_page=100" \
             --jq '.[] | select(.state=="CHANGES_REQUESTED" and ((.body // "") | (startswith("## Verdict: REJECT") or startswith("# Review Report")))) | "\(.id) \(.commit_id // "")"'); then
  echo "WARNING: could not list reviews for PR #$PR — dismiss manually." >&2
  exit 1
fi

# The PR's current head — the comparand every staleness test below is made
# against. Resolved LAZILY, only once a candidate exists, so the common path
# (nothing outstanding) still costs exactly one API call. A head that cannot
# be established is fail-closed: no review can be SHOWN stale against an
# unknown head, so nothing is dismissed and the caller is told the PR stays
# blocked. `.head.sha` is validated as a plausible object name here because it
# decides a selection — an empty read, a jq `null`, or an error blob must not
# silently become a value that compares unequal to every commit_id and so
# waves every candidate through.
HEAD_SHA=""
if [ -n "$ROWS" ]; then
  if ! HEAD_SHA=$("$DEVFLOW_GH" api "repos/$REPO/pulls/$PR" --jq '.head.sha'); then
    echo "WARNING: could not read the current head of PR #$PR — dismissed nothing (a review is only stale against a known head). Dismiss manually if appropriate." >&2
    exit 1
  fi
  if [[ ! "$HEAD_SHA" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    echo "WARNING: the current head of PR #$PR did not read back as a commit SHA ('${HEAD_SHA}') — dismissed nothing. Dismiss manually if appropriate." >&2
    exit 1
  fi
fi

FAILED=0
REFUSED=0
# Fields are split by `read` (a builtin) and compared with `[` — CLAUDE.md
# guard-class 2: a value deciding a SELECTION is never routed through a
# non-preflight PATH tool such as tr/sed/cut, which would come back empty on a
# host that lacks it and select the wrong thing.
while read -r RID RCOMMIT; do
  [ -n "$RID" ] || continue
  if [ -z "$RCOMMIT" ]; then
    echo "WARNING: review $RID on PR #$PR records no commit_id, so it cannot be shown superseded — NOT dismissed. Dismiss it manually if it is stale." >&2
    REFUSED=1
    continue
  fi
  if [ "$RCOMMIT" = "$HEAD_SHA" ]; then
    echo "WARNING: review $RID on PR #$PR was recorded against the PR's current head ($RCOMMIT), so it is not superseded — NOT dismissed. Its findings are about the commit being approved; resolve them, or dismiss it manually." >&2
    REFUSED=1
    continue
  fi
  # Capture stderr so a real failure cause (404/422/429/5xx) is surfaced
  # rather than collapsed into a misleading permissions guess.
  if ERR=$("$DEVFLOW_GH" api -X PUT "repos/$REPO/pulls/$PR/reviews/$RID/dismissals" \
       -f message="Superseded by a later APPROVE verdict from Devflow Review (review $RID was recorded against commit $RCOMMIT, which is no longer this pull request's head $HEAD_SHA)." \
       -f event=DISMISS 2>&1 >/dev/null); then
    echo "Dismissed stale CHANGES_REQUESTED review $RID on PR #$PR (recorded against $RCOMMIT; head is now $HEAD_SHA)."
  else
    echo "WARNING: could not dismiss review $RID on PR #$PR — dismiss it manually. (${ERR:-no error output})" >&2
    FAILED=1
  fi
done <<< "$ROWS"
[ "$FAILED" -eq 0 ] || exit 1
[ "$REFUSED" -eq 0 ] || exit 3
exit 0
