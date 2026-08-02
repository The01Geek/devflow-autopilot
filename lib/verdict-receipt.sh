#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# verdict-receipt.sh — the SINGLE SOURCE of the Phase 4.4 verdict-post receipt: the
# path both ends compose, and the best-effort write the producer performs (issue #1156).
#
# WHY A RECEIPT EXISTS. A standalone `prflow:review` cloud run can reach a verdict,
# publish it as an ordinary pull-request comment it composed itself, exit `success`,
# and leave NO trace that Phase 4.4 never ran: the reviews API stays empty for the
# reviewed head, `reviewDecision` keeps whatever a superseded round left there, and
# every post-run backstop stays silent because the run did not fail. Issue #1059's
# diagnostic apparatus — scripts/post-review-verdict.sh's closed outcome vocabulary —
# begins at that helper's FIRST LINE, so a run that never invokes it produces none of
# it. The receipt is what makes "the post was refused" (an outcome line naming a
# refusal) and "the post was never reached" (no receipt at all) two DIFFERENT durable
# states rather than the same silence.
#
# WHY THIS FILE, and not a literal repeated at both ends. The producer writes the
# receipt and scripts/check-verdict-post-reached.sh reads it; a path the two compose
# independently is a coupled literal whose drift is silent — the reader would answer
# NOT-REACHED for every run, i.e. it would report the exact failure it exists to
# detect, on runs that were fine. One function, both callers.
#
# WHY .prflow/tmp AND NOT the transitional state-directory resolver. The receipt is
# ephemeral run scratch written and read inside ONE job, never state carried across
# runs, so there is no installed consumer copy to migrate and nothing to fall back to:
# whichever directory this composes, both ends compose the same one. The `.prflow/tmp`
# tree is also the one the cloud review profile already grants writes against, and it
# is gitignored, so nothing here can dirty a tree.
#
# Defines only; deliberately no set -e/-u — safe to source into a caller with its own
# shell options.

# The path, relative to the repository root. Coupled with the `Write(.prflow/tmp/**)`
# grant the review profile carries; a receipt written outside that subtree would be
# refused on the cloud tier.
DEVFLOW_VERDICT_RECEIPT_RELPATH='.prflow/tmp/review-verdict-receipt.txt'

# devflow_verdict_receipt_path
#   Prints the absolute receipt path on stdout, always exit 0.
#
#   Repo-root anchoring is the #295 contract: `git rev-parse --show-toplevel`, falling
#   back to `pwd` when there is no git root. Both ends of this receipt run in the SAME
#   job at the same workspace root, so they resolve the same answer; the fallback keeps
#   the function total on a non-git tree (which is also how the suite isolates a
#   fixture — it runs the helpers with the working directory inside a scratch tree).
devflow_verdict_receipt_path() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
  [ -n "$root" ] || root="$(pwd)"
  printf '%s' "$root/$DEVFLOW_VERDICT_RECEIPT_RELPATH"
}

# devflow_verdict_receipt_record MODE LINE
#   MODE `start` truncates the receipt and writes LINE as its first line; `add`
#   appends LINE. Returns 0 when the bytes landed, 1 on any failure — and it is
#   SILENT on both, because the caller owns the breadcrumb (a producer that emits one
#   line per failed write would emit two for one broken directory).
#
#   `start` rather than append-always is load-bearing for idempotency: a second
#   invocation inside the same job (the review engine posting once per round, or a job
#   retry) must REPLACE the earlier outcome, never accumulate behind it, or the reader
#   would answer with a superseded round's outcome line.
#
#   Every redirection runs inside a subshell whose stderr is discarded: a failed
#   redirection is reported by the SHELL before the command runs, so `printf … 2>/dev/null`
#   would still leak the diagnostic into the producer's stderr and, on a caller running
#   under `set -e`, abort it.
devflow_verdict_receipt_record() {
  local mode="${1:-}" line="${2-}" path dir
  path="$(devflow_verdict_receipt_path)"
  [ -n "$path" ] || return 1
  dir="${path%/*}"
  mkdir -p "$dir" 2>/dev/null || return 1
  case "$mode" in
    start) ( printf '%s\n' "$line" > "$path" ) 2>/dev/null || return 1 ;;
    add)   ( printf '%s\n' "$line" >> "$path" ) 2>/dev/null || return 1 ;;
    *)     return 1 ;;
  esac
  return 0
}
