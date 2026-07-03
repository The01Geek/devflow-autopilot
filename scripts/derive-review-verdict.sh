#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# derive-review-verdict.sh — derive the Devflow Review verdict for the CURRENT
# HEAD, fail-closed. This is the small, testable unit extracted out of
# devflow-review.yml's finalize_check `success)` branch (issue #249): the
# workflow step calls it, and lib/test/run.sh drives it directly with a stubbed
# `gh` over the full input-shape matrix.
#
# The required `Devflow Review` check must encode a positively-observed APPROVE
# for the commit under review. Everything else fails CLOSED so an un-reviewed
# HEAD never merges (in either direction):
#   - The engine ended in error (is_error) .................... incomplete
#   - No PR number / no HEAD SHA (unverifiable) .............. incomplete
#   - Unresolvable REPO (owner/name) (unverifiable) ......... incomplete
#   - Reviews-API / comments-API query failed, or their JSON
#     could not be parsed (unverifiable) .................... incomplete
#   - Only older-commit reviews / empty reviews for HEAD .... incomplete
#   - No HEAD review and no run id to scope the comment
#     fallback (unverifiable) ............................... incomplete
#   - A CHANGES_REQUESTED (or `## Verdict: REJECT`) ON HEAD .. reject
#   - An APPROVED (or `## Verdict: APPROVE`) review ON HEAD .. approve
#   - A DISMISSED or PENDING review ON HEAD is never the verdict (a dismissed
#     review is a human override; its stale body must not resurrect) — such
#     reviews are skipped as if absent
#   - No HEAD review, but this run's run-keyed progress
#     comment carries a `## Verdict:` line for HEAD ......... reject/approve
# `incomplete` is distinct from `reject`: finalize_check maps it to a blocking
# `failure` titled "Devflow review incomplete — re-run needed", and it NEVER
# triggers the stale-REJECT dismissal (only a positively-observed APPROVE does).
#
# Producer contract (skills/review/SKILL.md Phase 4.4) this consumes:
#   REJECT (any form) -> `gh pr review --request-changes` -> state
#     CHANGES_REQUESTED, body first line `## Verdict: REJECT ...`
#   APPROVE with notes / CAVEAT -> `gh pr review --comment` -> state COMMENTED,
#     body first line `## Verdict: APPROVE ...`  (so a positive APPROVE is NOT
#     always state APPROVED — the body marker is the second signal)
#   APPROVE (clean) -> `gh pr review --approve` -> state APPROVED
#   Same-identity self-review fallback (`gh pr review` fails) -> the verdict is
#     recovered from THIS run's run-keyed `devflow:review-progress` PROGRESS
#     comment, which embeds the full report + the `## Verdict:` line and is the
#     only artifact this helper matches in step 6 (it carries the run-keyed
#     `<!-- devflow:review-progress run=<id>- -->` marker). Issue comments carry
#     no commit_id, so scoping is by that run-keyed marker, never a historical
#     comment. NOTE: the separate `gh pr comment` self-review fallback comment
#     the skill posts DOES carry a `## Verdict:` line, but it lacks the run-keyed
#     progress marker, so this helper does NOT read it — matching it un-scoped
#     (by `## Verdict:` alone, across all issue comments) is exactly the stale-/
#     prior-run-verdict resurrection this HEAD-scoping fix removes.
#
# Inputs (environment; all optional, absence fails closed where it matters):
#   HEAD_SHA       current HEAD SHA (needs.precheck.outputs.head_sha)
#   ENGINE_ERROR   "true" if the review engine execution ended is_error
#   PR_NUMBER      the pull request number
#   REPO           owner/name (defaults to `$DEVFLOW_GH repo view` when empty)
#   GITHUB_RUN_ID  this workflow run id (scopes the comment fallback marker)
#
# Output (stdout, two lines, always emitted):
#   verdict=<approve|reject|incomplete>
#   verdict_determined=<true|false>
# `verdict_determined` is true only when a verdict was positively observed from a
# successful lookup; it gates finalize_check's irreversible stale-REJECT
# dismissal exactly as before. Every no-verdict/unverifiable path emits
# `incomplete`/`false` with a SPECIFIC stderr breadcrumb naming which condition
# fired. Always exits 0 (best-effort, like dismiss-stale-rejections.sh) — the
# caller reads the verdict, not the exit code.
#
# $DEVFLOW_GH overrides the `gh` binary and $DEVFLOW_JQ the `jq` binary (the same
# seams the rest of devflow uses; both honored by the sourced resolvers below).

set -uo pipefail

_DRV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Guarded source (documented partial-copy posture — see CLAUDE.md): a deployment
# carrying this file without its sibling lib/resolve-gh.sh must degrade to bare
# `gh` with a breadcrumb, never assign an empty DEVFLOW_GH from an undefined
# devflow_resolve_gh (which would misdirect the failure to the reviews query).
# shellcheck source=../lib/resolve-gh.sh
. "$_DRV_DIR/../lib/resolve-gh.sh" \
  || echo "devflow: resolve-gh.sh could not be sourced from ../lib relative to ${BASH_SOURCE[0]} — using bare 'gh' (set DEVFLOW_GH to override)" >&2
# Sourceability is not function-availability (a sibling can source clean yet not
# define the resolver) — verify the function itself before calling it.
if type devflow_resolve_gh >/dev/null 2>&1; then
  : "${DEVFLOW_GH:=$(devflow_resolve_gh)}"
else
  # Partial-copy degradation only (resolver absent, breadcrumb above): the `:-`
  # form is the sanctioned fallback shape — the #245 peer-completeness pin
  # forbids the `:=gh` default precisely so full deployments route the resolver.
  DEVFLOW_GH="${DEVFLOW_GH:-gh}"
fi
# Guarded source (documented partial-copy posture — see CLAUDE.md): a deployment
# carrying this file without its sibling lib/resolve-jq.sh must degrade to bare
# `jq` with a breadcrumb, never leave DEVFLOW_JQ unbound and abort the next
# reference under `set -u`.
# shellcheck source=../lib/resolve-jq.sh
. "$_DRV_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced from ../lib relative to ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

HEAD_SHA="${HEAD_SHA:-}"
ENGINE_ERROR="${ENGINE_ERROR:-false}"
PR_NUMBER="${PR_NUMBER:-}"
REPO="${REPO:-}"
RUN_ID="${GITHUB_RUN_ID:-}"

# The `## Verdict:` heading the skill writes as the verdict artifact's first
# line. REJECT is any `--request-changes`; APPROVE covers every approve form
# (APPROVE / APPROVE with notes / APPROVE WITH CAVEAT / APPROVE WITH ADVISORY
# NOTES) since they all begin with the word APPROVE.
REJECT_RE='^##[[:space:]]+Verdict:[[:space:]]*REJECT'
APPROVE_RE='^##[[:space:]]+Verdict:[[:space:]]*APPROVE'

emit() { printf 'verdict=%s\nverdict_determined=%s\n' "$1" "$2"; exit 0; }

# 1. Engine execution ended in error -> no verdict for HEAD, regardless of any
#    existing (necessarily older-commit) reviews.
if [ "$ENGINE_ERROR" = "true" ]; then
  echo "derive-review-verdict: review engine execution ended in error (is_error=true) — treating as no verdict for HEAD; concluding incomplete." >&2
  emit incomplete false
fi

# 2. Unverifiable without a PR number -> fail closed (was: default to success).
if [ -z "$PR_NUMBER" ]; then
  echo "derive-review-verdict: empty PR_NUMBER — verdict cannot be verified; failing closed (incomplete)." >&2
  emit incomplete false
fi

# 3. Without the HEAD SHA the verdict cannot be scoped to the current commit ->
#    fail closed rather than trusting a possibly-stale review.
if [ -z "$HEAD_SHA" ]; then
  echo "derive-review-verdict: empty HEAD_SHA — cannot scope the verdict to the current HEAD; failing closed (incomplete)." >&2
  emit incomplete false
fi

# Derive REPO if the caller did not pass it (the workflow always does; this keeps
# the unit runnable standalone). A failure here is unverifiable -> fail closed.
if [ -z "$REPO" ]; then
  REPO="$("$DEVFLOW_GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
  echo "derive-review-verdict: could not resolve REPO (owner/name) — verdict unverifiable; failing closed (incomplete)." >&2
  emit incomplete false
fi

# 4. Query the reviews API. A failed query is unverifiable -> fail closed (this
#    reverses the prior default-to-success; deliberate per issue #249).
#    `--paginate` walks every page: GitHub returns reviews OLDEST-first, so on a
#    PR with >100 reviews a single page would cut off exactly the newest (HEAD)
#    review and fail-closed-wedge the PR with a misdiagnosing "no verdict"
#    breadcrumb. Paginated output is CONCATENATED arrays ("[...][...]"), which
#    the `-s`/`add` normalization in the jq filters below flattens.
if ! REVIEWS_JSON=$("$DEVFLOW_GH" api --paginate "repos/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" 2>/dev/null); then
  echo "derive-review-verdict: reviews API query failed for PR #$PR_NUMBER — verdict unverifiable; failing closed (incomplete)." >&2
  emit incomplete false
fi

# 5. HEAD-scoped selection: the LAST review whose commit_id equals HEAD_SHA. A
#    review on any earlier commit is never treated as the verdict (an empty
#    match set yields empty STATE/RBODY and falls through to the comment
#    fallback). Piped through jq (DEVFLOW_JQ) rather than gh --jq so the test
#    stub only has to echo JSON. A jq FAILURE (missing/broken jq, or a
#    200-but-non-array payload `map()` rejects) is NOT an empty match set: it
#    fails closed here with its own breadcrumb — falling through to the comment
#    fallback could emit a verdict without the reviews ever being consulted,
#    and the step-7 breadcrumb would misdiagnose a parse failure as "no verdict".
#    Only VERDICT-BEARING states are selected: a DISMISSED review is a human
#    override whose body still carries its old `## Verdict:` line — reading it
#    would resurrect a deliberately-dismissed verdict (the same Direction-1
#    wedge this helper exists to remove); a PENDING (or other non-verdict)
#    review interleaved on HEAD must not mask a real APPROVED/CHANGES_REQUESTED
#    posted just before it. Excluded states fall through like an empty set.
#    The leading `-s`/`add` normalizes the `--paginate` shape: slurp turns one
#    array into [[...]] and concatenated pages into [[...],[...]], and `add`
#    flattens both to one review list (a non-array payload with scalar values —
#    the real gh error-object shape — still errors in `map()`, keeping the parse
#    guard live; an all-empty input errors in `add|map` likewise — fail-closed
#    either way).
DRV_STATE_FILTER='add | map(select(.commit_id == $h and ((.state // "") | IN("APPROVED","CHANGES_REQUESTED","COMMENTED")))) | last'
if ! STATE=$(printf '%s' "$REVIEWS_JSON" | "$DEVFLOW_JQ" -rs --arg h "$HEAD_SHA" \
          "$DRV_STATE_FILTER | (.state // \"\")" 2>/dev/null); then
  echo "derive-review-verdict: reviews JSON could not be parsed (jq failed or the reviews payload was not an array) — verdict unverifiable; failing closed (incomplete)." >&2
  emit incomplete false
fi
if ! RBODY=$(printf '%s' "$REVIEWS_JSON" | "$DEVFLOW_JQ" -rs --arg h "$HEAD_SHA" \
          "$DRV_STATE_FILTER | (.body // \"\")" 2>/dev/null); then
  echo "derive-review-verdict: reviews JSON could not be parsed (jq failed or the reviews payload was not an array) — verdict unverifiable; failing closed (incomplete)." >&2
  emit incomplete false
fi

# REJECT first (fail toward blocking): a CHANGES_REQUESTED, or a REJECT verdict
# marker, on the HEAD review.
if [ "$STATE" = "CHANGES_REQUESTED" ] || printf '%s\n' "$RBODY" | grep -qE "$REJECT_RE"; then
  emit reject true
fi
# Positively-observed APPROVE on HEAD: a clean APPROVED, or the APPROVE verdict
# marker on a COMMENTED (approve-with-notes/caveat) review.
if [ "$STATE" = "APPROVED" ] || printf '%s\n' "$RBODY" | grep -qE "$APPROVE_RE"; then
  emit approve true
fi

# 6. No verdict review on HEAD. Fall back to THIS run's run-keyed progress
#    comment, which embeds the verdict line. Scope by the run marker (issue
#    comments carry no commit_id), so a prior run's verdict comment is ignored.
if [ -z "$RUN_ID" ]; then
  echo "derive-review-verdict: no HEAD-scoped review verdict and GITHUB_RUN_ID is empty — cannot scope the comment fallback to this run; failing closed (incomplete)." >&2
  emit incomplete false
fi
if ! COMMENTS_JSON=$("$DEVFLOW_GH" api --paginate "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" 2>/dev/null); then
  echo "derive-review-verdict: no HEAD-scoped review verdict and the issue-comments query failed for PR #$PR_NUMBER — failing closed (incomplete)." >&2
  emit incomplete false
fi

# The skill keys its live progress comment by `<!-- devflow:review-progress
# run=<RUN_ID>-<ATTEMPT> -->`, so matching the `run=<RUN_ID>-` prefix selects
# only this run's comment(s) across attempts.
MARKER="<!-- devflow:review-progress run=${RUN_ID}-"
# Same jq fail-closed posture as step 5 (and the same `-s`/`add` pagination
# normalization — comments are also oldest-first, and >100 issue comments is the
# realistic case on a chatty PR): a parse failure must not be read as "no
# matching comment" and land in step 7's misdiagnosing breadcrumb.
if ! CBODY=$(printf '%s' "$COMMENTS_JSON" | "$DEVFLOW_JQ" -rs --arg m "$MARKER" \
          'add | map(select((.body // "") | contains($m))) | last | (.body // "")' 2>/dev/null); then
  echo "derive-review-verdict: issue-comments JSON could not be parsed (jq failed or the comments payload was not an array) — verdict unverifiable; failing closed (incomplete)." >&2
  emit incomplete false
fi

if printf '%s\n' "$CBODY" | grep -qE "$REJECT_RE"; then
  emit reject true
fi
if printf '%s\n' "$CBODY" | grep -qE "$APPROVE_RE"; then
  emit approve true
fi

# 7. Nothing positively observed for HEAD -> incomplete (the PR #250 verdict-less
#    stall lands here: a run-keyed progress comment frozen at "Verdict: (pending)"
#    matches neither marker).
echo "derive-review-verdict: no verdict for HEAD (no HEAD-scoped review state and no run-keyed verdict comment for this run) — concluding incomplete." >&2
emit incomplete false
