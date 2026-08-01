#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# post-ci-review-trigger.sh — post the bare standalone review-trigger comment on a
# pull request, at most once per head SHA.
#
# SOLE CALLER: the `auto_review_trigger` job in .github/workflows/ci.yml. That
# workflow is REPO-INTERNAL — install.sh's copy loop ships only devflow.yml and
# devflow-implement.yml, so no consumer repo has ci.yml, nothing consumer-facing
# calls this helper, and the standing "a collaborator posts the review comment"
# statement in the shipped docs is untouched.
#
# Division of labour with the calling job:
#   * The job's `if:` decides ELIGIBILITY, entirely in GitHub-evaluated expressions
#     so no credential is minted for an ineligible run: both CI jobs green, a
#     non-draft `pull_request` whose head repo IS this repo (the fork gate), not
#     dependabot, and an App configured.
#   * This helper owns the remaining POST-or-SKIP selection. That is a branch
#     selection over a user-visible outcome, so it lives in a script the suite can
#     drive arm by arm rather than inline in YAML — the scripts/describe-denial-count.sh
#     precedent CLAUDE.md names.
#
# CONTRACT
#   * ALWAYS exits 0 (best-effort notification; it must never redden CI). Every
#     no-post arm leaves a DISTINCT annotation naming the condition that fired, so
#     a silent no-op is impossible to confuse with a posted trigger.
#   * The idempotency read FAILS CLOSED. When the comment list cannot be
#     established the helper does NOT post. The two costs are asymmetric: a missed
#     notification is recoverable (a collaborator can still comment the trigger by
#     hand — the pre-existing supported path — and the next green head fires again),
#     while a duplicate is unrecoverable paid review spend that repeats on every
#     workflow re-run for as long as the read stays broken. A dedupe guard that
#     posts when it cannot verify has no bounding property at all, which is exactly
#     the "a guard whose comparand can be absent fails open where it claims to fail
#     closed" class CLAUDE.md warns about.
#   * The success annotation is gated on post-issue-comment.sh's own success
#     breadcrumb, never on its exit code — that helper is best-effort and always
#     exits 0, so a failed POST would otherwise be annotated as a fired trigger
#     (the review stall backstop's issue-#408 lesson).
#
# THE PAYLOAD IS DELIBERATELY BARE: the SHA-keyed dedupe marker, a blank line, and
# the plain review command alone on its own line. Nothing else. devflow.yml's gate
# substring-tests the WHOLE body, detect-standalone-command.sh requires the command
# to be the sole content of its line, and any extra prose is a hazard rather than a
# courtesy. It must never widen to the fix-loop command: that path mints an App
# token and pushes with it, and an App-token push is NOT covered by GitHub's
# recursion guard, so it would re-run CI, re-post, and loop without bound. The
# review path mints no App token (devflow.yml's `app-token` step is skipped on a
# `/prflow:review ` command) and pushes nothing.
#
# Inputs (env):
#   PR        the pull-request number the comment goes on (required, numeric)
#   HEAD_SHA  the reviewed head commit (required, lowercase hex 7..40) — it keys
#             the marker, so dedupe is per-SHA and a new head always re-notifies
#   MODE      `post` (default) or `compose`
#   GH_TOKEN  consumed by gh; the caller sets it to the minted App token
#
# MODE=compose writes ONLY the composed body to stdout and touches no network. It
# is the seam the suite drives the payload contract through, so the body the test
# inspects is byte-identical to the body a real run posts.
set -uo pipefail

_PCRT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# gh binary: the single-source execution-verified resolver; an explicit DEVFLOW_GH
# still wins with no probe, so the suite's stubs are untouched. Guarded source so a
# partial copy degrades with a breadcrumb instead of aborting under `set -u`.
# shellcheck source=../lib/resolve-gh.sh
. "$_PCRT_DIR/../lib/resolve-gh.sh" \
  || echo "devflow: resolve-gh.sh could not be sourced from ../lib relative to ${BASH_SOURCE[0]} — using bare 'gh' (set DEVFLOW_GH to override)" >&2
if type devflow_resolve_gh >/dev/null 2>&1; then
  : "${DEVFLOW_GH:=$(devflow_resolve_gh)}"
else
  # Partial-copy degradation only: the `:-` form is the sanctioned fallback shape
  # — the #245 peer-completeness pin forbids a bare `:=gh` default.
  DEVFLOW_GH="${DEVFLOW_GH:-gh}"
fi

PR="${PR:-}"
HEAD_SHA="${HEAD_SHA:-}"
MODE="${MODE:-post}"

# Annotation sink. In `post` mode the runner parses workflow commands off this
# step's stdout, so annotations go there. In `compose` mode stdout is reserved for
# the composed body — a breadcrumb mixed into it would corrupt the payload the
# caller is asking for — so they go to stderr instead.
_note() {  # $1=notice|warning  $2=message
  if [ "$MODE" = compose ]; then
    printf 'devflow: %s: %s\n' "$1" "$2" >&2
  else
    printf '::%s::%s\n' "$1" "$2"
  fi
}

# Validate BEFORE composing. HEAD_SHA is interpolated into the marker and into the
# jq filter that reads the comment list, so a non-hex value is refused rather than
# embedded: it keeps the marker's shape a machine-comparable constant and leaves
# the filter free of anything jq or the shell would treat as special.
case "$PR" in
  ''|*[!0-9]*)
    _note warning "ci auto-review trigger: PR number '$PR' is missing or non-numeric; no trigger comment posted."
    exit 0 ;;
esac
if ! [[ "$HEAD_SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
  _note warning "ci auto-review trigger: head SHA '$HEAD_SHA' is missing or not a lowercase hex commit id; no trigger comment posted for PR #$PR."
  exit 0
fi

# The dedupe marker. Keyed on the head SHA, so a re-run over the SAME head is
# suppressed while every NEW green head notifies again — the deliberate design,
# not a first-time-only latch.
MARKER="<!-- prflow:ci-review-trigger sha=$HEAD_SHA -->"

# Compose the body. One function so `compose` mode and the POST path can never
# drift into two different payloads.
_compose_body() {
  printf '%s\n\n' "$MARKER"
  printf '/prflow:review\n'
}

if [ "$MODE" = compose ]; then
  _compose_body
  exit 0
fi

# --- Idempotency read (fail-closed) -----------------------------------------
# `{owner}/{repo}` placeholders, which gh fills from the git remote, NOT an
# interpolated $GITHUB_REPOSITORY: this file lives under scripts/ and so is a
# surface that can run outside Actions, where that variable has no producer and
# the path would collapse to `repos//issues/…` while gh wrote the HTTP error body
# to stdout (issue #664; lib/test/lint-gh-api-repo-path.py enforces it here).
# --paginate so a long-lived PR whose marker sits past page one is still seen.
# The filter emits one comment id per hit; a page with no hit emits nothing.
LIST_ERR="$(mktemp 2>/dev/null || echo /dev/null)"
if ! LIST_OUT="$("$DEVFLOW_GH" api --paginate "repos/{owner}/{repo}/issues/${PR}/comments" \
      --jq ".[] | select((.body // \"\") | contains(\"$MARKER\")) | .id" 2>"$LIST_ERR")"; then
  _note warning "ci auto-review trigger: could not read PR #$PR comments to check for an existing trigger ($(tr '\n' ' ' < "$LIST_ERR")); NOT posting (fail-closed — a duplicate standalone review is unrecoverable spend, a missed one is not)."
  [ "$LIST_ERR" = /dev/null ] || rm -f "$LIST_ERR"
  exit 0
fi
[ "$LIST_ERR" = /dev/null ] || rm -f "$LIST_ERR"

# Decide with bash builtins only. `tr`/`sed`/`wc` are not preflight-guaranteed, and
# a missing one would empty the pipeline and silently flip this selection to
# "post" — the un-guaranteed-tool trap CLAUDE.md names. (The `tr` above is inside a
# breadcrumb, where a missing tool only empties a diagnostic.)
ALREADY=false
while IFS= read -r _id; do
  case "$_id" in
    ''|*[!0-9]*) : ;;
    *) ALREADY=true ;;
  esac
done <<EOF
$LIST_OUT
EOF

if [ "$ALREADY" = true ]; then
  _note notice "ci auto-review trigger: PR #$PR already carries a trigger comment for $HEAD_SHA; nothing to post."
  exit 0
fi

# --- Post -------------------------------------------------------------------
# Body through a FILE so newlines never traverse shell quoting. mktemp is guarded
# distinctly: an unguarded failure would leave BODY_FILE empty and misdiagnose as a
# POST failure.
BODY_FILE="$(mktemp)" || {
  _note warning "ci auto-review trigger: mktemp failed; could not compose the trigger comment for PR #$PR (nothing posted)."
  exit 0
}
_compose_body > "$BODY_FILE"

POST="$_PCRT_DIR/post-issue-comment.sh"
if [ ! -f "$POST" ]; then
  _note warning "ci auto-review trigger: post-issue-comment.sh absent at $POST; trigger comment not posted for PR #$PR."
  rm -f "$BODY_FILE"
  exit 0
fi
# post-issue-comment.sh is best-effort and ALWAYS exits 0, so its exit code is not a
# success signal. Gate the success annotation on its exact breadcrumb instead.
POST_OUT="$(bash "$POST" "$PR" "$BODY_FILE" 2>&1)"
printf '%s\n' "$POST_OUT"
rm -f "$BODY_FILE"
if printf '%s\n' "$POST_OUT" | grep -qxF "devflow: posted comment on #$PR"; then
  _note notice "ci auto-review trigger: posted the review trigger on PR #$PR for $HEAD_SHA."
else
  _note warning "ci auto-review trigger: the review trigger comment did NOT post on PR #$PR for $HEAD_SHA; no review was requested."
fi
exit 0
