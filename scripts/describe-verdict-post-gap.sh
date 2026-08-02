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
#   ARM not-reached        the emitter provably did not run. One warning naming the run
#                          id and the pull-request number, and ONE cause-naming comment.
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

# The comment body's fixed tail, as a single-quoted literal so no byte of it is
# expanded by the shell. It is emitted with `printf` — a BUILTIN — and never through
# `cat`, which lib/preflight.sh does not guarantee: a host without it would post a
# truncated body, and the body IS the emitted result this whole step exists to produce.
_DVG_BODY_TAIL='Phase 4.4'"'"'s verdict emitter did not run in this run, so it left no run-scoped receipt
of an outcome. That is a different state from a verdict post that was issued and
refused, which would have left a receipt naming the refusal.

Because the emitter did not run, the reviews API and `reviewDecision` for this pull
request are unchanged by this run.

Any verdict text this run published elsewhere — a plain pull-request comment, for
example — carries no producer-emitted verdict marker, and the verdict-derivation
consumers do not read it as a verdict.

This comment is a record of that gap. It is not a verdict, and it neither approves nor
rejects this pull request.'

# The comment body. Its first line is a marker so the record is greppable, and it
# carries NO producer verdict marker — the whole point of the comment is that this run
# produced no verdict. The three validated fields are substituted by printf.
_dvg_body() {
  printf '<!-- prflow:verdict-post-gap run=%s -->\n' "$RUN_ID"
  printf '**PRFlow review: the verdict emitter did not run in this run.**\n\n'
  printf -- '- Actions run id: `%s`\n' "$RUN_ID"
  printf -- '- Pull-request head SHA this step resolved: `%s`\n\n' "$HEAD_SHA"
  printf '%s\n' "$_DVG_BODY_TAIL"
}

case "$READER_LINE" in
  'REACHED '*)
    printf 'ARM %s\n' reached
    ;;
  'NOT-REACHED')
    _dvg_write "$WARNING_FILE" "PRFlow review: Phase 4.4's verdict emitter did not run in Actions run $RUN_ID for pull request #$PR_NUMBER; the reviews API and reviewDecision are unchanged by this run"
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
