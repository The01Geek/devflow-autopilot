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
#                                     [WARNING_FILE] [BODY_FILE]
#   READER_LINE   check-verdict-post-reached.sh's single stdout line (possibly empty).
#   WARNING_FILE  truncated on every arm; written with one line on the four non-reached
#                 arms. Omit (or pass empty) to skip the write.
#   BODY_FILE     truncated on every arm; written only on `not-reached`.
# Prints one `ARM <arm>` line to stdout. Always exits 0 — the step that consumes this
# must never change the invoking job's pass or its fail.
set -u

READER_LINE="${1:-}"
RUN_ID="${2:-}"
PR_NUMBER="${3:-}"
HEAD_SHA="${4:-}"
WARNING_FILE="${5:-}"
BODY_FILE="${6:-}"

# ── Field validation. `unavailable` is the single literal for every value that did not
# resolve, matching the vocabulary permission_denials_count already publishes.
[[ "$RUN_ID" =~ ^[0-9]+$ ]] || RUN_ID=unavailable
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || PR_NUMBER=unavailable
[[ "$HEAD_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || HEAD_SHA=unavailable

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
# API is unchanged. That is CLAUDE.md's "unknown is not zero" rule one level down: the
# reader correctly refuses to collapse *unreadable* onto NOT-REACHED, so the comment
# must not then collapse *write-failed* onto "did not run". It names the observation,
# both causes, and the one check that separates them.
#
# The tail is a single-quoted literal so no byte of it is expanded by the shell, and it
# is emitted with `printf` — a BUILTIN — never through `cat`, which lib/preflight.sh
# does not guarantee: a host without it would post a truncated body, and the body IS
# the emitted result this whole step exists to produce.
_DVG_BODY_TAIL='No run-scoped verdict-post receipt was found for this run: either Phase 4.4'"'"'s
verdict emitter did not run, or it ran and could not write its receipt (look for a
`could not write the verdict-post receipt` breadcrumb in the job log). If a formal
review exists in the reviews API for the head above, the emitter ran.

Those two causes differ in what they imply here, which is why this comment asserts
neither. If the emitter did not run, it recorded no verdict anywhere and this run left
the reviews API and `reviewDecision` untouched. If it ran but could not write its
receipt, whatever it posted stands and this comment says nothing about it. Reading the
reviews API for the head above is what tells them apart.

Any verdict text this run published OUTSIDE the emitter — a plain pull-request comment,
for example — carries no producer-emitted verdict marker, and the verdict-derivation
consumers do not read it as a verdict.

This comment is a record of that gap. It is not a verdict, and it neither approves nor
rejects this pull request.'

# The comment body. Its first line is a marker so the record is greppable, and it
# carries NO producer verdict marker — this run reached no verdict this step can see.
# The three validated fields are substituted by printf.
_dvg_body() {
  printf '<!-- prflow:verdict-post-gap run=%s -->\n' "$RUN_ID"
  printf '**PRFlow review: no verdict-post receipt was found for this run.**\n\n'
  printf -- '- Actions run id: `%s`\n' "$RUN_ID"
  printf -- '- Pull-request head SHA this step resolved: `%s`\n\n' "$HEAD_SHA"
  printf '%s\n' "$_DVG_BODY_TAIL"
}

case "$READER_LINE" in
  'REACHED '*)
    printf 'ARM %s\n' reached
    ;;
  'NOT-REACHED')
    _dvg_write "$WARNING_FILE" "PRFlow review: no run-scoped verdict-post receipt was found for Actions run $RUN_ID on pull request #$PR_NUMBER — either Phase 4.4's verdict emitter did not run, or it ran and could not write its receipt; the posted comment names the check that tells them apart"
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
