#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Aggregator gate for the macOS Bash 3.2 portability lane (issue #1277).
#
# The stable check `portability / macOS Bash 3.2` is this aggregator job, which runs
# with `if: always()` so it still reports when the producer fails, cancels, or is
# skipped. That makes the producer's result AND its emitted domain result the gate's
# two operands: without both, the check would go green over a lane that never ran.
#
# Two operands, and neither alone is enough. The producer's Actions conclusion says
# whether the JOB completed; the domain result says what the LANE concluded. A
# producer that completes while emitting `fail` is a real incompatibility, and a
# producer that emits `pass` after being cancelled mid-run emitted it about a corpus
# it did not finish — so the gate requires agreement, not either signal.
#
# This lives in a script rather than inline in ci.yml so the suite can DRIVE each arm
# (CLAUDE.md: inline workflow shell that selects a branch or composes a user-facing
# message is extracted into a helper — a grep-pin on a message literal is not
# coverage of the selection that chooses it).
#
# Usage: bash lib/test/gate-portability-result.sh "<needs.<producer>.result>" <domain-result-file>
# Exit 0 only when the producer conclusion is the literal `success` AND the domain
# result file holds the literal `pass` or a fully-established `not_applicable`.
# Every other combination — including an absent conclusion, an absent or unreadable
# file, an empty one, and any unrecognised token — exits 1 with a GitHub `::error::`
# annotation naming what was observed.

set -u

conclusion="${1-}"
result_file="${2-}"

printf 'portability producer conclusion: %s\n' "$conclusion"

# Fail closed on an UNESTABLISHED conclusion. An empty value means the expression that
# should have carried the producer outcome resolved to nothing (a renamed job, a
# dropped `needs:` edge); passing the check over an outcome nobody observed is the
# un-gating trap this helper exists to close — unknown is not success.
if [ -z "$conclusion" ]; then
  printf '::error::the portability producer conclusion was not supplied — refusing to pass the stable check over an unestablished lane outcome\n'
  exit 1
fi

if [ "$conclusion" != "success" ]; then
  printf '::error::the portability producer did not succeed (%s) — failure, cancellation and skip all fail this check\n' "$conclusion"
  exit 1
fi

if [ -z "$result_file" ]; then
  printf '::error::no domain-result file was named — a successful producer conclusion alone does not establish what the lane concluded\n'
  exit 1
fi

# An ABSENT artifact is the staleness/absence arm: the producer reported success but
# its result never arrived (an upload that failed, a download that silently produced
# nothing). That is unestablished, not a pass.
if [ ! -f "$result_file" ]; then
  printf '::error::the domain-result file %s is absent — the producer reported success but emitted no result for this run\n' "$result_file"
  exit 1
fi

domain=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "DOMAIN_RESULT: "*) domain="${line#DOMAIN_RESULT: }" ;;
  esac
done < "$result_file"

# The value is extracted with shell builtins only. `grep`/`sed`/`cut` are NOT
# preflight-guaranteed, and a missing one would leave `domain` empty — which this
# gate would then correctly but misleadingly report as an unestablished lane, hiding
# a tooling gap behind a portability verdict.
if [ -z "$domain" ]; then
  printf '::error::%s carries no DOMAIN_RESULT line — the lane emitted no domain result, which is unestablished rather than a pass\n' "$result_file"
  exit 1
fi

printf 'portability domain result: %s\n' "$domain"

case "$domain" in
  pass)
    exit 0
    ;;
  not_applicable)
    # Reachable only from a FULLY ESTABLISHED classification: the supervisor emits
    # this token when the classifier established the changed-file population and it
    # selected no portable surface. An unestablished classification never reaches
    # here — it arrives at the producer as the complete portable population instead,
    # so a degraded read produces `pass`/`fail`, never this.
    printf 'no portable surface was selected by a fully-established classification; nothing to verify on this head\n'
    exit 0
    ;;
  fail)
    printf '::error::the macOS Bash 3.2 lane failed\n'
    exit 1
    ;;
  *)
    printf '::error::unrecognised domain result %s — the closed set is pass, fail, not_applicable; refusing to pass the stable check over a value this gate cannot interpret\n' "$domain"
    exit 1
    ;;
esac
