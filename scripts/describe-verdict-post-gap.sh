#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-verdict-post-gap.sh — select the arm the Phase 4.4 reach record takes, and
# compose every byte that arm emits (issue #1156).
#
# WHY A HELPER rather than an inline `if`/`else` chain in devflow.yml: the arm IS the
# diagnosis. A silently mis-selected arm (a reordered chain, a glob typo) tells a
# maintainer the wrong thing about a wedged pull request while the workflow still
# "works", and a grep-pin on a message literal is not coverage of the selection that
# chooses it. Inline shell inside YAML cannot be unit-tested; here a focused test
# module drives every arm AND the arm order directly. Same class, and the same
# extraction, as scripts/describe-denial-count.sh (issue #363) and
# scripts/describe-dead-run-cause.sh (issue #1154).
#
# THE CALLER DOES NOT BRANCH. This helper writes the warning text and the comment body
# into two caller-supplied files, TRUNCATING both on every arm, and prints one `ARM …`
# line. The workflow then emits a warning iff the warning file is non-empty and posts a
# comment iff the body file is non-empty — two mechanical consequences, no selection of
# its own. That is what keeps the whole decision inside a surface the suite can drive.
#
# ARMS (closed; the ARM token is the machine-readable answer, the files are the bytes):
#
#   ARM reached            the emitter ran. Silent: no warning, no comment.
#   ARM not-reached        NO RECEIPT WAS FOUND. One warning naming the run id and the
#                          pull-request number, and ONE comment naming both causes that
#                          produce an absent receipt and the check that separates them.
#                          It does NOT assert that the emitter did not run — see the
#                          body's own comment block below for why that would be false.
#   ARM unestablished      the reader could not settle the question. One warning
#                          carrying the reader's reason VERBATIM. No comment — the
#                          not-reached claim is exactly what was not established.
#   ARM no-line            the reader produced no output at all, which on the cloud tier
#                          means it was refused before it ran (the harness/permission
#                          matcher denies silently) or is absent from this deployment.
#                          Warns; asserts nothing.
#   ARM unrecognized-line  the reader produced a line outside its own closed vocabulary.
#                          Warns; asserts nothing.
#
# `no-line` and `unrecognized-line` are kept APART deliberately. Both warn without
# asserting, so folding them would not change what the pull request sees — but they
# have different remedies (a missing grant or a missing file, versus a reader that
# spoke and was not understood), and the workflow log is the only place that
# distinction survives.
#
# ARM ORDER IS LOAD-BEARING in two places. The empty reader line is also matched by the
# trailing catch-all, so the `no-line` arm must precede it or a refused reader is
# reported as one that spoke gibberish. And the catch-all must stay LAST: hoisted above
# the specific arms it swallows every input, reporting a reached emitter as an
# unrecognized line.
#
# EVERY EMITTED FIELD IS VALIDATED, NOT QUOTED. The run id and pull-request number are
# accepted only as digit strings and the head SHA only as 40 hex characters; anything
# else — including the empty string a failed `gh api … --jq .head.sha` lookup leaves —
# is rendered as the literal `unavailable`. So no value this helper did not recognize
# reaches a `::warning::` or a pull-request comment, and `unavailable` is the honest
# answer for a lookup that did not resolve rather than a blank a reader would misread
# as zero. The reader's reason is likewise a closed token by construction
# (check-verdict-post-reached.sh never quotes receipt bytes), so the verbatim reason
# carries nothing receipt-derived either.
#
# Selection values are derived with bash builtins only (`case`, `[[ =~ ]]`, parameter
# expansion) — never `tr`/`sed`/`wc`/`cut`, which lib/preflight.sh does not guarantee
# and whose absence yields an empty value and the wrong arm.
#
# Usage: describe-verdict-post-gap.sh READER_LINE RUN_ID PR_NUMBER HEAD_SHA \
#                                     [WARNING_FILE] [BODY_FILE] [REVIEW_CLASS]
#   READER_LINE   check-verdict-post-reached.sh's single stdout line (possibly empty).
#   WARNING_FILE  truncated on every arm; written with one line on the four non-reached
#                 arms. Omit (or pass empty) to skip the write.
#   BODY_FILE     truncated on every arm; written only on `not-reached`.
#   REVIEW_CLASS  classify-head-reviews.sh's single line for the reviewed head — `none`,
#                 `marked`, `unmarked <id>…`, `unestablished <reason>`, or empty (an
#                 older deployment, or a step that did not classify). Selects the
#                 not-reached body's middle paragraph and warning: the API is asserted
#                 untouched only on `none`, the offending review is named on `unmarked`,
#                 and nothing is asserted either way on `unestablished`/empty (issue
#                 #1250). Ignored on every arm other than not-reached.
# Prints one `ARM <arm>` line to stdout. Always exits 0 — the step that consumes this
# must never change the invoking job's pass or its fail.
# `-f` (noglob) so the unquoted `$RC_REST` in the unmarked-id token loop below cannot
# pathname-expand against the workflow checkout (defense-in-depth: the classifier emits
# digits only, but this is a general positional-arg consumer). Nothing here globs.
set -uf

READER_LINE="${1:-}"
RUN_ID="${2:-}"
PR_NUMBER="${3:-}"
HEAD_SHA="${4:-}"
WARNING_FILE="${5:-}"
BODY_FILE="${6:-}"
# REVIEW_CLASS is scripts/classify-head-reviews.sh's single line for the reviewed head
# (issue #1250): `none`, `marked`, `unmarked <id>…`, `unestablished <reason>`, or empty
# on an older deployment / a step that did not classify. It disambiguates the ONE
# observation the reader gives on receipt absence — the reviews API was written to, or
# not — so the not-reached body stops asserting the API was untouched when it was not.
REVIEW_CLASS="${7:-}"

# ── Field validation. `unavailable` is the single literal for every value that did not
# resolve, matching the vocabulary permission_denials_count already publishes.
[[ "$RUN_ID" =~ ^[0-9]+$ ]] || RUN_ID=unavailable
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || PR_NUMBER=unavailable
[[ "$HEAD_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || HEAD_SHA=unavailable

# ── Parse REVIEW_CLASS into a validated kind + safe payload. The classifier's vocabulary
# is closed, but this parse never trusts that: the ids are re-validated as digit strings
# and the reason as a lowercase token, so no payload byte can reach a `::warning::` or a
# comment even if a future producer widened the vocabulary. An `unmarked` line with no
# valid id, and any unrecognized kind, degrade to `unestablished` — the direction that
# asserts nothing.
RC_KIND="${REVIEW_CLASS%% *}"
RC_REST="${REVIEW_CLASS#"$RC_KIND"}"
RC_REST="${RC_REST# }"
RC_IDS=""
RC_REASON=""
case "$RC_KIND" in
  none|marked) : ;;
  unmarked)
    for _rc_tok in $RC_REST; do
      [[ "$_rc_tok" =~ ^[0-9]+$ ]] && RC_IDS="${RC_IDS:+$RC_IDS }$_rc_tok"
    done
    [ -n "$RC_IDS" ] || RC_KIND=unestablished ;;
  unestablished)
    [[ "$RC_REST" =~ ^[a-z][a-z-]*$ ]] && RC_REASON="$RC_REST" ;;
  *) RC_KIND=unestablished ;;
esac

# Truncate both sinks on EVERY arm, before any arm is selected: a stale file left by an
# earlier step (or an earlier attempt of this one) would otherwise be read by the
# caller's `[ -s … ]` test as this run's answer, posting a comment on the reached arm.
_dvg_reset() {
  local target="${1:-}"
  [ -n "$target" ] || return 0
  ( : > "$target" ) 2>/dev/null || return 0
}
_dvg_write() {
  local target="${1:-}" text="${2-}"
  [ -n "$target" ] || return 0
  ( printf '%s\n' "$text" > "$target" ) 2>/dev/null || return 0
}
_dvg_reset "$WARNING_FILE"
_dvg_reset "$BODY_FILE"

# THIS ARM STATES WHAT WAS OBSERVED, NOT WHAT WAS INFERRED. The reader answers
# NOT-REACHED on receipt ABSENCE, and absence has TWO causes: the emitter never ran, or
# it ran and its best-effort receipt write failed (post-review-verdict.sh's own KNOWN
# RESIDUAL). A body asserting "the emitter did not run" would therefore publish a false
# statement on a pull request whenever the second cause applies with a `POSTED review`
# outcome — a formal review sitting in the reviews API while a public comment says the
# API is unchanged. Issue #1250 is the sharper version of the same failure: `gh api` is
# granted in every capability profile, so a run that never reached the emitter can still
# have POSTED a real, merge-blocking review directly through the reviews endpoint —
# unmarked, so no verdict consumer reads it. The categorical "left the reviews API and
# `reviewDecision` untouched" the earlier body carried was therefore observed FALSE on a
# live run (30860699039 / review 4849248513). So the middle paragraph is now chosen from
# REVIEW_CLASS — scripts/classify-head-reviews.sh's reading of the reviews actually
# recorded on the head — and it asserts the API was untouched only on the `none` arm
# where that was measured, names the offending review on the `unmarked` arm, and asserts
# nothing either way on `unestablished`/empty. This is CLAUDE.md's "unknown is not zero"
# rule two levels down.
#
# Every paragraph is a single-quoted literal so no byte of it is expanded by the shell,
# and the body is emitted with `printf` — a BUILTIN — never through `cat`, which
# lib/preflight.sh does not guarantee: a host without it would post a truncated body,
# and the body IS the emitted result this whole step exists to produce. The one
# substituted value in the middle paragraph is RC_IDS, which the parse above reduced to
# digit tokens.
_DVG_INTRO='No run-scoped verdict-post receipt was found for this run: either Phase 4.4'"'"'s
verdict emitter did not run, or it ran and could not write its receipt (look for a
`could not write the verdict-post receipt` breadcrumb in the job log).'

# The class-appropriate middle paragraph. Printed by _dvg_middle so the RC_IDS
# substitution stays inside printf rather than a heredoc/expansion.
_DVG_MID_MARKED='This run'"'"'s reviewer identity recorded a MARKED review in the reviews API for the
head above: its first line carries the producer-emitted verdict marker, so the
verdict-derivation consumers do read it as a verdict. Only the receipt is missing.'
_DVG_MID_NONE='No review authored by this run'"'"'s reviewer identity is recorded in the reviews
API for the head above, so this run left the reviews API and `reviewDecision` untouched.
It recorded no verdict anywhere.'
_DVG_MID_CLOSING='Any verdict text this run published OUTSIDE the emitter carries no producer-emitted verdict marker,
and the verdict-derivation consumers do not read it as a verdict.

This comment is a record of that gap. It is not a verdict, and it neither approves nor
rejects this pull request.'

_dvg_middle() {
  case "$RC_KIND" in
    unmarked)
      printf 'This run'"'"'s reviewer identity DID write to the reviews API for the head above:\n'
      printf 'review %s is recorded there and carries no producer-emitted verdict marker on its\n' "$RC_IDS"
      printf 'first line. GitHub records it as a formal review that can set `reviewDecision`, but the\n'
      printf 'verdict-derivation consumers do not read an unmarked review as a verdict, so PRFlow'"'"'s\n'
      printf 'own tooling does not recognize it.\n'
      ;;
    marked)
      printf '%s\n' "$_DVG_MID_MARKED"
      ;;
    none)
      printf '%s\n' "$_DVG_MID_NONE"
      ;;
    *)  # unestablished / empty — assert NOTHING about the reviews API either way.
      if [ -n "$RC_REASON" ]; then
        printf 'Whether this run recorded any review in the reviews API for the head above could not\n'
        printf 'be established (%s); this comment asserts nothing about the reviews API either way.\n' "$RC_REASON"
      else
        printf 'Whether this run recorded any review in the reviews API for the head above was not\n'
        printf 'checked by this step; this comment asserts nothing about the reviews API either way.\n'
      fi
      printf 'Reading the reviews API for the head above is what settles it.\n'
      ;;
  esac
}

# The comment body. Its first line is a marker so the record is greppable, and it
# carries NO producer verdict marker — this run reached no verdict this step can see.
# The validated fields are substituted by printf.
_dvg_body() {
  printf '<!-- prflow:verdict-post-gap run=%s -->\n' "$RUN_ID"
  printf '**PRFlow review: no verdict-post receipt was found for this run.**\n\n'
  printf -- '- Actions run id: `%s`\n' "$RUN_ID"
  printf -- '- Pull-request head SHA this step resolved: `%s`\n\n' "$HEAD_SHA"
  printf '%s\n\n' "$_DVG_INTRO"
  _dvg_middle
  printf '\n%s\n' "$_DVG_MID_CLOSING"
}

# The not-reached WARNING names the offending review id on the `unmarked` arm (issue
# #1250 AC6) — the one arm where a real merge-blocking review exists that no verdict
# consumer reads — and otherwise states the observation and both causes.
_dvg_notreached_warning() {
  if [ "$RC_KIND" = unmarked ]; then
    printf 'PRFlow review: run %s left an UNMARKED review (review %s) in the reviews API for pull request #%s while no verdict-post receipt was found — GitHub records it as a formal review that can set reviewDecision, but the verdict-derivation consumers do not read it as a verdict; the posted comment has the detail' \
      "$RUN_ID" "$RC_IDS" "$PR_NUMBER"
  else
    printf 'PRFlow review: no run-scoped verdict-post receipt was found for Actions run %s on pull request #%s — either Phase 4.4'"'"'s verdict emitter did not run, or it ran and could not write its receipt; the posted comment names the check that tells them apart' \
      "$RUN_ID" "$PR_NUMBER"
  fi
}

case "$READER_LINE" in
  'REACHED '*)
    printf 'ARM %s\n' reached
    ;;
  'NOT-REACHED')
    _dvg_write "$WARNING_FILE" "$(_dvg_notreached_warning)"
    if [ -n "$BODY_FILE" ]; then
      ( _dvg_body > "$BODY_FILE" ) 2>/dev/null || true
    fi
    printf 'ARM %s\n' not-reached
    ;;
  'UNESTABLISHED '*)
    _dvg_write "$WARNING_FILE" "PRFlow review: whether Phase 4.4's verdict emitter ran in Actions run $RUN_ID for pull request #$PR_NUMBER could not be established: ${READER_LINE#UNESTABLISHED }"
    printf 'ARM %s\n' unestablished
    ;;
  '')
    _dvg_write "$WARNING_FILE" "PRFlow review: whether Phase 4.4's verdict emitter ran in Actions run $RUN_ID for pull request #$PR_NUMBER could not be established: the verdict-post check produced no output (it was refused before it ran, or is absent from this deployment)"
    printf 'ARM %s\n' no-line
    ;;
  *)
    _dvg_write "$WARNING_FILE" "PRFlow review: whether Phase 4.4's verdict emitter ran in Actions run $RUN_ID for pull request #$PR_NUMBER could not be established: the verdict-post check produced a line outside its own closed vocabulary"
    printf 'ARM %s\n' unrecognized-line
    ;;
esac
exit 0
