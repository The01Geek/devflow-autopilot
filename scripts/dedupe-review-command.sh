#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Decide whether THIS standalone `/prflow:review` command is redundant because a
# review of the same pull request is already IN FLIGHT — Candidate C of issue
# #989. The redundancy signal is the review engine's own seeded live progress
# comment (`<!-- devflow:review-progress run=<id>-<attempt> -->`, body
# `**Status:** 🚀 Reviewing`), which only the review engine authors and which
# exists from Phase 0.3.5, before any review work — so it detects an *in-flight*
# review directly, the redundancy that actually costs an engine run.
#
# Why the seeded comment (not a run-list or the `Reviewed HEAD` line):
#   - A thread-scoped `gh run list` keys on every comment in the repository (this
#     workflow starts a run per comment), so it suppresses on unrelated
#     conversation and, carrying no head, on a legitimate re-request after a push.
#   - The `Reviewed HEAD` line is stamped only at Phase 4, so it identifies a
#     COMPLETED review, never an in-flight one.
# Only the review engine writes the seeded comment, so the candidate population is
# reviews rather than conversation, and no `run-name` / command-class matcher is
# needed. (See docs/workflow-triggers.md and issue #989's Decision section.)
#
# Two accepted, deliberate costs (issue #989):
#   1. Configuration-dependent: with devflow_review.live_progress_comment_enabled
#      off there is no seeded comment, so this fails OPEN (no suppression) — the
#      direction this job is already contractually required to take. The
#      absent-signal path still emits a breadcrumb.
#   2. Cross-class: a /prflow:review-and-fix run seeds the SAME comment, so a
#      /prflow:review issued during one is suppressed. This is correct — the
#      review-and-fix run executes the review engine, so the suppressed review
#      would have been redundant.
#
# GitHub-native `concurrency` is NOT the mechanism (shared repository doctrine —
# see scripts/dedupe-implement-run.sh's header and docs/workflow-triggers.md):
# `cancel-in-progress: true` cancels the in-flight run (wrong run) and `false`
# QUEUES the duplicate so it eventually runs (not ignored). GitHub has no
# "skip if already running" primitive, so both DevFlow duplicate checks — the
# implement path's and this command path's — detect duplicates themselves.
#
# MODES
#   MODE=detect (default) — decide suppression from the PR's comments.
#     Output (one key=value line on stdout; the workflow parses it with bash
#     builtins, tests assert it directly):
#         suppress=true|false
#   MODE=notice — compose the user-facing suppression notice for a decided cause.
#     Output: `notice=<text>` on stdout. The composition lives HERE, not in an
#     inline workflow `NOTE=` assignment, so the suite can drive the PRODUCED
#     message (a grep over an inline literal protects the literal, not the message
#     a rewording produces). CAUSE ∈ legacy-check-run|legacy-workflow-run|
#     inflight-review; HEAD is the resolved head SHA (first 7 chars are shown).
#
# Inputs (env):
#   MODE           detect (default) | notice.
#   REPO           owner/repo, for the `gh api` comments call (detect mode).
#   PR             the pull-request / thread number to inspect (detect mode). The
#                  workflow derives it as
#                  `github.event.issue.number || github.event.pull_request.number`
#                  so it resolves on all three events devflow.yml accepts.
#   RUN_ID         github.run_id of THIS run — a review-progress comment keyed to
#                  this run (run=<RUN_ID>-...) is excluded, so a run can never
#                  suppress on its own seeded comment.
#   TRIGGER_BODY   the triggering comment's body. A `/prflow:review` carrying the
#                  `<!-- devflow:review-backstop head=… attempt=… -->` marker is a
#                  no-verdict auto-resume posted from inside a still-active run;
#                  it is NEVER suppressed (that run's own progress comment would
#                  otherwise read as an active peer and swallow the resume).
#   REVIEW_INFLIGHT_MAX_AGE_MINUTES   liveness bound (default 120). A review run
#                  updates its progress comment per phase, so an in-flight run's
#                  comment is fresh; a KILLED run leaves the comment frozen in
#                  `🚀 Reviewing`, so a comment whose `updated_at` is older than
#                  this bound is treated as stale/frozen, NOT in-flight (open
#                  question 1 of issue #989).
#   CAUSE, HEAD    notice mode only (see MODE=notice above).
#   DEDUPE_NOW_EPOCH  test hook: fixes "now" for the liveness bound. When unset the
#                  jq `now` builtin is used.
#   DEVFLOW_GH     gh executable override for tests; resolved via lib/resolve-gh.sh
#                  when unset/empty.
#   DEVFLOW_JQ     jq executable override; resolved via lib/resolve-jq.sh.
#
# Fails OPEN in every direction: a missing input, a query error, an unparseable
# response, an unresolvable jq, or an absent signal all yield suppress=false with
# a SPECIFIC ::warning:: breadcrumb — because a missed suppression just reproduces
# the recoverable double-comment, whereas a wrong suppression silently swallows a
# review the user explicitly asked for. The value that DECIDES suppression is
# derived only with jq and bash builtins — never tr/sed/wc/cut/head — so a missing
# non-preflight PATH tool cannot yield an empty value that reads as "no duplicate".

set -euo pipefail

# jq binary: resolved once via the resolver sourced from the sibling lib/ (issue
# #247); a copied/vendored deployment without lib/ falls back to bare `jq` with a
# breadcrumb rather than aborting under set -e.
# shellcheck source=../lib/resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced from ../lib relative to ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

emit() { printf '%s=%s\n' "$1" "$2"; }

# The marker the review engine seeds its live progress comment with, and the
# in-flight status line it carries until the Phase-4 terminal flip. Kept identical
# to skills/review/SKILL.md's template (lib/test/run.sh pins the agreement).
PROGRESS_MARKER='<!-- devflow:review-progress'
INFLIGHT_STATUS='🚀 Reviewing'
# The marker a stall-backstop review auto-resume comment carries (kept identical
# to the MARKER scripts/post-review-backstop-comment.sh writes; pinned agreeing).
BACKSTOP_MARKER='<!-- devflow:review-backstop'

mode="${MODE:-detect}"

# ── notice composition ──────────────────────────────────────────────────────
# CRITICAL: every notice body must carry NO DevFlow trigger phrase (no `/prflow:`,
# `/devflow:`, `@claude`). Under the optional App token this comment fires a real
# issue_comment event, so a trigger substring here would re-enter the gate and
# loop. The legacy causes name the `Devflow Review` check + its Re-run button
# because on a consumer whose installed copy predates the withheld tier those are
# the reader's real actions; the in-flight-review cause names its own reason.
if [ "$mode" = "notice" ]; then
  head7="${HEAD:0:7}"
  case "${CAUSE:-}" in
    legacy-check-run|legacy-workflow-run)
      emit notice "ℹ️ An automated **Devflow Review** is already running for this commit (\`${head7}\`). Skipping this manual review command to avoid a duplicate review and double comments. Use the **Re-run** button on the \`Devflow Review\` check if you need to re-review." ;;
    inflight-review)
      emit notice "ℹ️ A review of this pull request is already in progress for this commit (\`${head7}\`). Skipping this duplicate review command so the pull request receives a single review. The in-progress review will post its verdict when it finishes — comment again once it has completed if you need a fresh review." ;;
    *)
      echo "::warning::dedupe-review notice: unknown CAUSE '${CAUSE:-}'; emitting no notice." >&2
      emit notice ""
      exit 0 ;;
  esac
  exit 0
fi

# ── detect mode ─────────────────────────────────────────────────────────────

# A stall-backstop review auto-resume is NEVER suppressed: it is posted from
# inside a still-active run whose own seeded comment would otherwise read as an
# active peer. Match the marker in the triggering body (bash builtin substring).
case "${TRIGGER_BODY:-}" in
  *"$BACKSTOP_MARKER"*)
    echo "::notice::dedupe-review: triggering comment carries the review-backstop marker (a no-verdict auto-resume); not suppressing." >&2
    emit suppress false
    exit 0 ;;
esac

repo="${REPO:-}"
pr="${PR:-}"
run_id="${RUN_ID:-}"
window_min="${REVIEW_INFLIGHT_MAX_AGE_MINUTES:-120}"

# Fail open on a missing/invalid thread key or repo: an unresolvable operand must
# never suppress. (RUN_ID is optional — a missing one only weakens self-exclusion,
# which cannot wrongly suppress, so it fails open silently to an empty string.)
if [ -z "$repo" ]; then
  echo "::warning::dedupe-review: REPO is unset; not suppressing (manual review proceeds)." >&2
  emit suppress false
  exit 0
fi
if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
  echo "::warning::dedupe-review: PR thread number unresolved/invalid ('${pr}'); not suppressing (manual review proceeds)." >&2
  emit suppress false
  exit 0
fi
if ! [[ "$window_min" =~ ^[0-9]+$ ]]; then
  echo "::warning::dedupe-review: REVIEW_INFLIGHT_MAX_AGE_MINUTES ('${window_min}') is not a non-negative integer; not suppressing." >&2
  emit suppress false
  exit 0
fi
window_s=$(( window_min * 60 ))

# gh binary: resolved once via the single-source resolver (execution-verified); an
# explicit DEVFLOW_GH still wins, so test stubs are untouched.
# shellcheck source=../lib/resolve-gh.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"
GH="$DEVFLOW_GH"

# List the PR's comments as RAW JSON (no `--jq`): the helper does ALL parsing in
# its own jq below, so the malformed-response matrix is exercised at the helper's
# boundary rather than swallowed by gh's own `--jq`. `--paginate` over a REST array
# endpoint concatenates the pages into one JSON array. A query failure fails OPEN
# with its own breadcrumb.
if ! comments_json="$("$GH" api --paginate "repos/$repo/issues/$pr/comments" 2>/dev/null)"; then
  echo "::warning::dedupe-review: comments query failed for PR #$pr; not suppressing (fail-open)." >&2
  emit suppress false
  exit 0
fi

# Distinguish an empty response from a genuinely-empty array: `--jq` over an empty
# body prints nothing (empty stdout), which is a degraded read, not `[]`.
if [ -z "$comments_json" ]; then
  echo "::warning::dedupe-review: comments query returned an empty response for PR #$pr; not suppressing (fail-open)." >&2
  emit suppress false
  exit 0
fi

# The deciding value is computed by jq and validated by a bash regex — never by a
# non-preflight PATH tool. `now` is jq's builtin; a test fixes it by passing a
# positive DEDUPE_NOW_EPOCH, which the program prefers over `now` — chosen ONCE
# inside jq (a single static program), never string-spliced.
jq_err="$(mktemp 2>/dev/null || echo /dev/null)"
# Program emits two space-separated integers: <inflight-match count> <malformed
# in-flight candidate count>. A candidate = a bot-authored, marker-carrying,
# 🚀 Reviewing comment not keyed to THIS run; it is a MATCH when its updated_at
# parses and is within the liveness window, and MALFORMED when updated_at is
# absent/null/unparseable (so liveness cannot be established → fail open on it).
decision="$("$DEVFLOW_JQ" -r \
  --argjson fixed_now "${DEDUPE_NOW_EPOCH:-0}" \
  --argjson window "$window_s" \
  --arg marker "$PROGRESS_MARKER" \
  --arg status "$INFLIGHT_STATUS" \
  --arg runself "run=${run_id}-" '
  def isprogress: ((.body // "") | type == "string") and ((.body // "") | contains($marker)) and ((.body // "") | contains($status)) and ((.user.type // "") == "Bot");
  def notself: ((.body // "") | contains($runself)) | not;
  def freshdate: (.updated_at // null) | (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T");
  (if $fixed_now > 0 then $fixed_now else now end) as $n
  | if type != "array" then error("not-array")
  else
    ( [ .[] | select(isprogress) | select(notself) | select(freshdate)
          | select( ($n - (.updated_at | fromdateiso8601)) <= $window
                    and ($n - (.updated_at | fromdateiso8601)) >= 0 ) ] | length ) as $m
    | ( [ .[] | select(isprogress) | select(notself) | select(freshdate | not) ] | length ) as $bad
    | "\($m) \($bad)"
  end' <<<"$comments_json" 2>"$jq_err")" || decision=""

jq_diag="$(tr '\n' ' ' < "$jq_err" 2>/dev/null || printf '')"
[ "$jq_err" = /dev/null ] || rm -f "$jq_err"

# An unresolvable jq (e.g. DEVFLOW_JQ pointed at a non-existent binary) or a parse
# error leaves $decision empty / non-conforming. Name jq explicitly so an empty
# decision is never read as "no duplicate".
if ! [[ "$decision" =~ ^[0-9]+\ [0-9]+$ ]]; then
  case "$jq_diag" in
    *not-array*)
      echo "::warning::dedupe-review: comments response was not a JSON array for PR #$pr; not suppressing (fail-open)." >&2 ;;
    *"No such file"*|*"not found"*|"")
      echo "::warning::dedupe-review: could not resolve jq (DEVFLOW_JQ='${DEVFLOW_JQ:-}'; ${jq_diag:-no diagnostic}); not suppressing (fail-open)." >&2 ;;
    *)
      echo "::warning::dedupe-review: could not parse the comments response for PR #$pr (jq: ${jq_diag}); not suppressing (fail-open)." >&2 ;;
  esac
  emit suppress false
  exit 0
fi

inflight="${decision% *}"
malformed="${decision#* }"

if [ "$malformed" -gt 0 ]; then
  echo "::warning::dedupe-review: $malformed in-flight review-progress comment(s) for PR #$pr carried an absent/unparseable updated_at; liveness could not be established for those — not counting them (fail-open)." >&2
fi

if [ "$inflight" -gt 0 ]; then
  echo "::notice::dedupe-review: $inflight in-flight review(s) already running for PR #$pr; suppressing this duplicate /prflow:review." >&2
  emit suppress true
else
  echo "::notice::dedupe-review: no in-flight review for PR #$pr; manual review proceeds." >&2
  emit suppress false
fi
