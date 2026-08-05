#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# record-empty-branch.sh — the cloud /prflow:implement stall backstop's empty-branch
# producer (issue #1261).
#
# When a terminated implement run pushed no commit to its remote feature branch,
# nothing today records that fact where a maintainer will see it: the branch
# exists and the workpad carries recorded progress, so the aftermath reads as a
# partially-completed attempt rather than an empty one. This helper is the
# producer's DECISION + the note it writes, extracted from the workflow YAML (the
# describe-denial-count.sh / post-review-backstop-comment.sh precedent) so
# lib/test/run.sh can drive every outcome against a scratch git repository and a
# stubbed workpad writer. `scripts/stall-backstop-decide.sh` stays pure and gains
# no I/O; the git/gh I/O the three-valued decision needs lives HERE, beside — not
# inside — that pure decision function (issue #1261 AC1).
#
# The decision is three-valued, NOT a boolean, per the repo's *unknown is not
# zero* rule: an unestablished measurement gets its own clause and is never
# collapsed onto "no commit reached the remote", which would report a data-loss
# event that may not have happened and invite a maintainer to discard a branch
# that has work on it.
#
# Inputs (environment):
#   ISSUE_NUMBER   The issue whose workpad receives the note.
#   BRANCH         The run's feature branch name. When empty it is parsed from the
#                  workpad `**Branch:**` line in EB_WORKPAD_BODY (a placeholder like
#                  `_(creating…)_` carries no backticks, so it stays empty). A
#                  still-empty value selects UNESTABLISHED (the branch name was
#                  unavailable — an unestablished case, never a no-commit one). The
#                  caller may pass it explicitly (the suite does, to drive each
#                  outcome); the workflow leaves it empty and lets the body parse
#                  resolve it, so the fragile line parse is exercised here rather
#                  than stranded in untestable workflow YAML.
#   BASE           The base branch (config .base_branch; default resolved by the
#                  caller). EMPTY selects UNESTABLISHED.
#   REMOTE         The git remote to probe (default: origin).
#   RUN_URL        The run's Actions URL, appended to the note for the reader.
#   V              The scripts dir holding workpad.py (default: this script's dir).
#   EB_WORKPAD_BODY  The live workpad body, used ONLY for idempotency: if it
#                  already carries this producer's marker, the note is not
#                  re-written (a second invocation on an unchanged workpad does
#                  not duplicate the statement). Optional; absent => not deduped.
#
# Prints exactly one `decision=<token>` line to stdout — the observable outcome
# the suite routes on (issue #1261 AC7):
#   decision=NO_COMMIT      the remote branch is 0 commits ahead of its base; the
#                           note IS written (AC2).
#   decision=HAS_COMMIT     the remote branch is >=1 commit ahead; NO note is
#                           written — the negative control (AC3).
#   decision=UNESTABLISHED  the branch/base name was unavailable, the remote was
#                           unreachable, or the commit query failed; the note says
#                           the fact could not be established (AC4).
# A `deduped=yes` token is appended to the decision line when the marker was
# already present and the write was skipped.
#
# Best-effort by contract (issue #1261 AC5): a failure to write the note emits a
# ::warning:: and always exits 0, so the caller's exit arm is never changed.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="${V:-$SELF_DIR}"
REMOTE="${REMOTE:-origin}"
ISSUE_NUMBER="${ISSUE_NUMBER-}"
BRANCH="${BRANCH-}"
BASE="${BASE-}"
RUN_URL="${RUN_URL-}"
EB_WORKPAD_BODY="${EB_WORKPAD_BODY-}"

# The idempotency + reader-facing marker. Kept in the note body so a maintainer
# (and this helper on a re-run) can recognise the empty-branch statement.
MARKER='<!-- prflow:empty-branch -->'

decision=""
reason=""

# Resolve the feature branch from the workpad `**Branch:**` line when the caller
# did not pass one explicitly. A placeholder (`_(creating…)_`) has no backticks,
# so the capture stays empty and the unestablished arm fires below.
if [ -z "$BRANCH" ] && [ -n "$EB_WORKPAD_BODY" ]; then
  BRANCH="$(printf '%s\n' "$EB_WORKPAD_BODY" | sed -n 's/^\*\*Branch:\*\* `\([^`]*\)`.*/\1/p' | head -n1)"
fi

if [ -z "$BRANCH" ] || [ -z "$BASE" ]; then
  decision=UNESTABLISHED
  reason="the run's branch name was unavailable"
else
  # Best-effort fetch of both refs into remote-tracking form. A failure here is
  # NOT fatal: the refs may already be present locally from an earlier fetch, and
  # if they are not, the rev-parse below fails closed to UNESTABLISHED.
  git fetch --quiet "$REMOTE" \
    "+refs/heads/$BASE:refs/remotes/$REMOTE/$BASE" \
    "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" >/dev/null 2>&1 || true

  head_sha="$(git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BRANCH" 2>/dev/null || true)"
  base_sha="$(git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BASE" 2>/dev/null || true)"

  if [ -z "$head_sha" ]; then
    # The remote branch could not be resolved: the remote is unreachable, the
    # branch was never created/pushed, or the query failed. This is the
    # unestablished case, NOT a no-commit one (issue #1261 gotcha: "a run whose
    # branch was never created is an unestablished case").
    decision=UNESTABLISHED
    reason="the remote branch \`$BRANCH\` could not be resolved on \`$REMOTE\` (unreachable, absent, or never pushed)"
  elif [ -z "$base_sha" ]; then
    decision=UNESTABLISHED
    reason="the base ref \`$REMOTE/$BASE\` could not be resolved"
  else
    ahead="$(git rev-list --count "refs/remotes/$REMOTE/$BASE..refs/remotes/$REMOTE/$BRANCH" 2>/dev/null || true)"
    if [[ ! "$ahead" =~ ^[0-9]+$ ]]; then
      decision=UNESTABLISHED
      reason="the ahead-of-base commit count could not be computed"
    elif [ "$ahead" -eq 0 ]; then
      decision=NO_COMMIT
    else
      decision=HAS_COMMIT
    fi
  fi
fi

# HAS_COMMIT is the negative control: work survived, so no statement is written —
# a statement that always appears carries no information (issue #1261 AC3).
if [ "$decision" = "HAS_COMMIT" ]; then
  echo "decision=$decision"
  exit 0
fi

# Idempotency: if the workpad already carries this producer's marker, do not
# duplicate the statement (a second invocation on an unchanged workpad is a
# no-op). Dedup is best-effort — an absent body simply writes.
if [ -n "$EB_WORKPAD_BODY" ] && printf '%s' "$EB_WORKPAD_BODY" | grep -qF "$MARKER"; then
  echo "decision=$decision deduped=yes"
  exit 0
fi

# Compose the note. The marker leads so it is greppable; the wording states the
# fact a reader can act on without deriving it.
if [ "$decision" = "NO_COMMIT" ]; then
  note="${MARKER}empty branch: no commit reached the remote branch \`$BRANCH\` beyond \`$BASE\` — this run left nothing on its branch (0 commits ahead of the base)."
else
  note="${MARKER}empty branch: could not establish whether any commit reached the remote branch — $reason. The branch may or may not carry work; this is not a confirmed no-commit outcome."
fi
[ -n "$RUN_URL" ] && note="$note — $RUN_URL"

if ! python3 "$V/workpad.py" update "$ISSUE_NUMBER" --note "$note" >/dev/null 2>&1; then
  echo "::warning::stall backstop: could not record the empty-branch statement on the workpad (decision=$decision); leaving it unwritten"
fi

echo "decision=$decision"
exit 0
