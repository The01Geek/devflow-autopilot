#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# classify-head-reviews.sh PAYLOAD HEAD_SHA REVIEWER_LOGIN — reduce a reviews-API
# payload to ONE line from a closed four-token vocabulary (issue #1250).
#
# THE QUESTION IT ANSWERS. `Bash(gh api:*)` is granted in every capability profile,
# so a cloud run that cannot reach scripts/post-review-verdict.sh can still POST a
# real, merge-blocking pull-request review by calling the reviews endpoint directly —
# a review GitHub records (it sets `reviewDecision`) but which carries NO
# producer-emitted `prflow:review-verdict` marker, so none of PRFlow's
# verdict-derivation consumers read it as a verdict (run 30860699039 / review
# 4849248513). scripts/post-review-verdict.sh is therefore NOT the sole granted post
# path, only the sole MARKING one. This helper looks at the reviews actually recorded
# on the reviewed head and reports whether the run's own reviewer identity left a
# marked review, an UNMARKED one (the bypass), none at all, or a shape it could not
# settle — so the Phase 4.4 reach record (scripts/describe-verdict-post-gap.sh,
# rendered by the devflow.yml reach-record step) can stop asserting the reviews API
# was untouched when it was not.
#
# CONTRACT — exactly one stdout line, always exit 0:
#
#   none                    no review authored by REVIEWER_LOGIN is recorded against
#                           HEAD_SHA (an empty list, a review by another login, or a
#                           review on a different commit all resolve here)
#   marked                  every own-identity review on the head carries the producer
#                           marker on its FIRST line
#   unmarked <id> [<id>…]   at least one own-identity review on the head carries no
#                           marker on line 1; the ids are the unmarked reviews', sorted
#                           ascending, space-separated on the one line
#   unestablished <reason>  the question could not be settled; <reason> is one closed
#                           token from the list below
#
# Always exit 0 because the only caller is an `always()` post-run workflow step that
# must never change its job's pass and never change its fail.
#
# UNKNOWN IS NOT ZERO. A payload that cannot be parsed, a head SHA that is absent, a
# reviewer login that is absent, or an own-identity review whose `body` is not a string
# are each UNESTABLISHED — never `none`. Collapsing any of them onto `none` would let
# the reach record assert "the reviews API is untouched" about a run it never actually
# measured, which is CLAUDE.md's "unknown is not zero" rule (the named prior instance is
# `permission_denials_count` publishing `0` for a run it never measured). The
# MARKER-ON-LINE-1 rule is deliberately strict: scripts/post-review-verdict.sh stamps the
# marker as line 1 of a review body, so a marker a finding quotes deeper in the body must
# NOT read as a stamp — a review with the marker on line 2 is `unmarked`, not `marked`.
#
# REASON VOCABULARY (closed; every arm emits one of these and nothing else):
#
#   head-sha-absent          HEAD_SHA was empty
#   reviewer-login-absent    REVIEWER_LOGIN was empty
#   payload-unreadable       the payload path is not a readable file
#   payload-unparseable      the payload is not valid JSON
#   payload-not-an-array     the payload parsed but its top level is not an array
#   body-not-a-string        an own-identity review on the head has a non-string body
#   classify-failed          the classifier produced no line at all
#
# The reasons are CLOSED TOKENS and never quote the payload's bytes. The caller renders
# the token into a `::warning::` and a pull-request comment; a reason that embedded
# payload bytes would carry whatever the review body contained onto those surfaces —
# including a `::warning::`/`##[…]` workflow command. Naming the SHAPE keeps every
# emitted surface free of payload-derived bytes. The one payload-derived value that DOES
# reach stdout — the review ids on the `unmarked` line — is produced by jq's `tostring`
# over the numeric `.id` field, so it is digits only by construction.
#
# Every selection value is derived through jq (a preflight-guaranteed tool) and bash
# builtins (`[`, `case`, parameter expansion) — never `tr`/`sed`/`wc`/`cut`/`head`,
# which lib/preflight.sh does not guarantee: a missing one yields an empty value and
# selects the wrong arm (CLAUDE.md guard-class 2).
#
# Usage: classify-head-reviews.sh PAYLOAD HEAD_SHA REVIEWER_LOGIN
#   PAYLOAD         path to a reviews-API JSON array, or `-` to read it from stdin.
#   HEAD_SHA        the reviewed head SHA the reviews are scoped to.
#   REVIEWER_LOGIN  the login of the run's own reviewer identity (`.user.login`).
set -u

# jq binary: resolved once via the single-source resolver (execution-verified); an
# explicit DEVFLOW_JQ still wins, so test stubs are untouched.
# shellcheck source=../lib/resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-jq.sh"

PAYLOAD="${1:-}"
HEAD="${2:-}"
LOGIN="${3:-}"

# (1) The two operands the classification cannot proceed without. Absent head or login
#     is UNESTABLISHED, never `none`: with either missing nothing about the reviews was
#     measured.
if [ -z "$HEAD" ]; then
  echo "unestablished head-sha-absent"
  exit 0
fi
if [ -z "$LOGIN" ]; then
  echo "unestablished reviewer-login-absent"
  exit 0
fi

# (2) Resolve the payload source. A file path that is not a readable file is
#     UNESTABLISHED payload-unreadable (the payload was never observed). Stdin (`-`) is
#     handed to jq directly.
_CHR_SRC=""
if [ "$PAYLOAD" = "-" ]; then
  _CHR_SRC="-"
else
  if [ ! -r "$PAYLOAD" ] || [ -d "$PAYLOAD" ]; then
    echo "unestablished payload-unreadable"
    exit 0
  fi
  _CHR_SRC="$PAYLOAD"
fi

# (3) Classify in jq. The program emits `none`, `marked`, `unmarked <ids>`, or an
#     `ERR <reason>` token that bash maps to a closed UNESTABLISHED reason. A jq parse
#     failure (invalid JSON) exits non-zero and is caught below as payload-unparseable.
#     `.user.login`/`.commit_id`/`.body` are indexed defensively: a missing object
#     yields null (jq does not error), and select() drops a review whose login or commit
#     does not match. The body-type check runs BEFORE any string op and short-circuits,
#     so a non-string body grades ERR rather than aborting the whole filter.
_CHR_PROG='
  def marker_line1:
    (.body | split("\n") | (.[0] // "")) as $l1
    # The shape test validates the full marker format; the startswith BINDS the marker'"'"'s
    # own head= field to the reviewed head. Otherwise a review recorded against the head but
    # carrying a marker for a DIFFERENT head would read as `marked` here while the
    # verdict-derivation consumers — which require the marker head to match — ignore it, so
    # the reach record would report a recorded verdict for a review nothing reads (a residual
    # of the very bypass this classifier flags). startswith is a literal string match, so the
    # head value never enters a regex.
    | ($l1 | test("^<!-- prflow:review-verdict head=[0-9a-fA-F]{40} verdict=(APPROVE|REJECT) -->"))
      and ($l1 | startswith("<!-- prflow:review-verdict head=" + $head + " verdict="));
  if (type != "array") then "ERR payload-not-an-array"
  else
    [ .[] | select((.commit_id == $head) and (.user.login == $login)) ] as $own
    | if ($own | length) == 0 then "none"
      elif ($own | map(.body | type) | any(. != "string")) then "ERR body-not-a-string"
      else
        [ $own[] | select(marker_line1 | not) | .id ] as $unmarked
        | if ($unmarked | length) > 0
          then "unmarked " + ($unmarked | sort | map(tostring) | join(" "))
          else "marked"
          end
      end
  end
'

_CHR_OUT=""
if [ "$_CHR_SRC" = "-" ]; then
  _CHR_OUT="$("$DEVFLOW_JQ" -r --arg head "$HEAD" --arg login "$LOGIN" "$_CHR_PROG" 2>/dev/null)" \
    || { echo "unestablished payload-unparseable"; exit 0; }
else
  _CHR_OUT="$("$DEVFLOW_JQ" -r --arg head "$HEAD" --arg login "$LOGIN" "$_CHR_PROG" "$_CHR_SRC" 2>/dev/null)" \
    || { echo "unestablished payload-unparseable"; exit 0; }
fi

# (4) Map the jq answer to the closed stdout vocabulary. An `ERR <reason>` becomes
#     `unestablished <reason>`; an empty answer (jq ran but produced nothing) is
#     classify-failed rather than a silent `none`.
case "$_CHR_OUT" in
  none|marked) echo "$_CHR_OUT" ;;
  'unmarked '*) echo "$_CHR_OUT" ;;
  'ERR '*)      echo "unestablished ${_CHR_OUT#ERR }" ;;
  *)            echo "unestablished classify-failed" ;;  # empty (jq ran, produced nothing) or an unexpected shape
esac
exit 0
