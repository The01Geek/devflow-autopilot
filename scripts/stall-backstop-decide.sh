#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# stall-backstop-decide.sh — pure decision function for the cloud /devflow:implement
# stall backstop (issue #266).
#
# A headless single-shot claude-code-action run can end mid-lifecycle (e.g. right
# after `gh pr create`) yet report success, because the SDK session ends the
# moment the model emits a tool-call-free turn. The workflow-level backstop keys
# on the issue workpad Status to detect that and either auto-resume or fail loud.
# This helper is the decision *core*, deliberately extracted from the workflow
# YAML so lib/test/run.sh can drive every branch deterministically with stubbed
# inputs — it does NO I/O (no gh/jq/workpad.py), just maps inputs to a decision.
#
# Usage: stall-backstop-decide.sh ENABLED CLASS ATTEMPTS MAX
#   ENABLED   The resolved `stall_backstop.enabled` config value. Only the exact
#             string "false" disables the backstop; every other value (empty,
#             "true", an unrecognized string) resolves to enabled — the safe,
#             honest-failure direction the issue mandates.
#   CLASS     The workpad status class from `workpad.py status`:
#               terminal      — 🎉 Complete / 👎 Blocked / 💥 Failed (a decided
#                               end; no resume. 💥 Failed is written by the
#                               workflow's own dead-run flip, issue #356, so a
#                               re-triggered run reads terminal -> noop here)
#               interim       — 🚀 any in-progress phase (a stall)
#               unreadable    — no workpad, or its Status could not be parsed
#               auth-failure  — a gh-api / transport / auth error (e.g. an
#                               expired App token) while reading the workpad
#                               Status or the comment list. Distinct from
#                               "unreadable": the workpad may be perfectly
#                               healthy — the READ failed, not the content.
#             (the workflow passes "unreadable" when `workpad.py status` exits 1
#             or 2, and "auth-failure" when it exits 3 or the comment-count
#             fetch fails on transport/auth grounds.) Any other/unknown token is
#             treated as unreadable.
#   ATTEMPTS  How many automatic resume attempts have already been made for this
#             issue (>=0). A non-integer resolves to 0 (fail toward attempting a
#             resume, not toward a spurious exhaustion).
#   MAX       The resolved `stall_backstop.max_resume_attempts` cap. A negative
#             or non-integer value resolves to the default 2. 0 is honored
#             verbatim (detect-and-fail-loud only, no auto-resume).
#
# Prints exactly one decision token to stdout and exits 0:
#   skip             backstop disabled            → do nothing, job stays green
#   noop             terminal status              → do nothing (healthy end)
#   resume           interim + ATTEMPTS < MAX     → audit comment + re-dispatch
#   fail-exhausted   interim + ATTEMPTS >= MAX     → comment + fail the job
#                    (includes MAX=0: 0 >= 0)
#   fail-unreadable  status unreadable/unknown    → diagnostic comment + fail
#   fail-auth        gh-api/transport/auth failure → auth-specific comment + fail
#                    (fails loud WITHOUT consuming a resume attempt; never
#                    mislabeled 'unreadable')
set -uo pipefail

enabled="${1-}"
cls="${2-}"
attempts="${3-}"
max="${4-}"

# Disabled only on the exact literal "false"; anything else (missing key handed a
# default by config-get, "true", or an unrecognized string) resolves to enabled.
if [ "$enabled" = "false" ]; then
  echo skip
  exit 0
fi

# Sanitize the numeric inputs. A non-integer attempt count → 0; a non-integer or
# negative cap → the documented default of 2 (the `^[0-9]+$` test rejects a
# leading "-", so "-1" falls back).
[[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
[[ "$max" =~ ^[0-9]+$ ]] || max=2

case "$cls" in
  terminal)
    echo noop
    ;;
  interim)
    if [ "$attempts" -ge "$max" ]; then
      echo fail-exhausted
    else
      echo resume
    fi
    ;;
  auth-failure)
    # A gh-api/transport/auth failure reading the workpad — NOT a corrupt
    # workpad. Fail loud with a distinct decision so the workflow emits an
    # auth-specific breadcrumb and never burns a resume attempt on a workpad it
    # never actually read. Placed before the wildcard so it isn't swallowed.
    echo fail-auth
    ;;
  unreadable|*)
    # 'unreadable' is the workflow's explicit "no workpad / unparseable Status"
    # token; any OTHER unexpected class is an unknown state treated the same way
    # — fail closed rather than silently no-op'ing on something we can't classify
    # (never pass on an unknown status).
    echo fail-unreadable
    ;;
esac
exit 0
