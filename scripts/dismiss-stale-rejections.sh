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
# that appeared since — that is the intended behavior, not non-idempotency.)
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
#   1  list query failed, or one or more dismissals failed (caller may
#      warn; never fatal there)
#   2  bad arguments

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
# body-marker filter is what scopes this to Devflow's own reviews.
if ! IDS=$("$DEVFLOW_GH" api --paginate "repos/$REPO/pulls/$PR/reviews?per_page=100" \
             --jq '.[] | select(.state=="CHANGES_REQUESTED" and ((.body // "") | (startswith("## Verdict: REJECT") or startswith("# Review Report")))) | .id'); then
  echo "WARNING: could not list reviews for PR #$PR — dismiss manually." >&2
  exit 1
fi

FAILED=0
while read -r RID; do
  [ -n "$RID" ] || continue
  # Capture stderr so a real failure cause (404/422/429/5xx) is surfaced
  # rather than collapsed into a misleading permissions guess.
  if ERR=$("$DEVFLOW_GH" api -X PUT "repos/$REPO/pulls/$PR/reviews/$RID/dismissals" \
       -f message="Superseded by a later APPROVE verdict from Devflow Review (review $RID predates the current passing review)." \
       -f event=DISMISS 2>&1 >/dev/null); then
    echo "Dismissed stale CHANGES_REQUESTED review $RID on PR #$PR."
  else
    echo "WARNING: could not dismiss review $RID on PR #$PR — dismiss it manually. (${ERR:-no error output})" >&2
    FAILED=1
  fi
done <<< "$IDS"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
