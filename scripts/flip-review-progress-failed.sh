#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# flip-review-progress-failed.sh <pr_number> <marker> <cause>
#
# Best-effort backstop (issue #356): when a review-engine run dies — the job
# fails, is cancelled, or the runner is lost before the agent can act — flip
# THIS run's `devflow:review-progress` comment from the interim `🚀 Reviewing`
# state to the terminal `❌ Review failed` state so its Status stops lying. This
# is the workflow-level mirror of the agent-side fatal-abort rule in
# skills/review/SKILL.md (the "Fatal review abort after seeding" clause); the
# `❌ Review failed` literal and the run-keyed marker shape are a coupled
# contract with that skill (pinned in lib/test/run.sh).
#
# Contract (mirrors ensure-label.sh / apply-labels.sh / post-issue-comment.sh):
#   - ALWAYS exits 0 — a flip hiccup must never change the invoking job's or
#     step's exit code (finalize_check runs `set -euo pipefail` on a REQUIRED
#     check; devflow.yml's step runs `always()`).
#   - Emits exactly one stderr breadcrumb naming the arm it took — e.g. flipped,
#     comment-absent, status-already-terminal, no-Status-line, missing-args, or
#     read/patch-failure. Each arm names the SPECIFIC condition that fired: a
#     failed comment lookup (`id` rc 1) is reported as a read failure, never as
#     "comment-absent" (rc 2), so an operator is never told the comment does not
#     exist when the read merely failed.
#   - Flips ONLY when the comment exists AND its `**Status:**` line begins with
#     🚀 (interim) — anything else (a written verdict, an agent-side
#     `❌ Review failed`, any terminal glyph) is treated as terminal and left
#     untouched (fail closed to no flip).
#   - The run-keyed marker (`<!-- devflow:review-progress run=<id>-<attempt> -->`)
#     matches ONLY the current run's comment, so an earlier run's comment is
#     never modified.
#
# All GitHub access routes through workpad.py (id/body/patch), which honors
# DEVFLOW_GH — so no bare `gh` caller is introduced (the resolve-gh convention
# holds by construction). The review comment's vocabulary is NOT workpad.py's
# (`Review failed` is unrecognized there and `--status` would stamp the wrong
# glyph), so the Status line is rewritten textually and the full body PATCHed —
# the same full-body-rewrite model the skill itself uses.
set -uo pipefail

PR="${1:-}"
MARKER="${2:-}"
CAUSE="${3:-review run ended without a verdict}"

# `workpad.py id` declares its issue arg `type=int`, so ARGPARSE also exits 2 on a
# usage error — the same code `cmd_id` uses for "scanned cleanly, no match". Keep the
# rc-2 arm below unambiguous by refusing a non-numeric PR here, so the only rc 2 that
# can reach it is the genuine comment-absent one (a guard's accepted-input set must be
# a subset of its consumer's contract, not wider).
if [ -z "$PR" ]; then
  echo "flip-review-progress-failed: usage: flip-review-progress-failed.sh <pr_number> <marker> <cause>; empty pr number — no-op (a non-PR event, or an unresolved pr_number output)" >&2
  exit 0
fi
if [ -z "$MARKER" ]; then
  echo "flip-review-progress-failed: usage: flip-review-progress-failed.sh <pr_number> <marker> <cause>; empty marker — no-op (the caller failed to build the run-keyed marker)" >&2
  exit 0
fi
case "$PR" in
  *[!0-9]*)
    echo "flip-review-progress-failed: usage: pr number '${PR}' is not numeric — no-op (refusing it here keeps 'workpad.py id' rc 2 unambiguous: argparse also exits 2 on a usage error)" >&2
    exit 0
    ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKPAD="$HERE/workpad.py"

# Run link for the appended cause line (standard runner env; a local run leaves
# these empty). The reusable runner shares GITHUB_RUN_ID/ATTEMPT with the caller,
# so the URL points at the dead run.
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
else
  RUN_URL="(run link unavailable)"
fi

# 1. Locate THIS run's comment. The run-keyed marker matches only the current
#    run, so a prior run's comment is never a candidate. `id`'s two failure
#    exits mean DIFFERENT things and must not share a breadcrumb: rc 2 is a
#    clean scan that found no comment (flag off, non-PR mode, /pr-description
#    runs, seed failure), while rc 1 is a gh-api/parse failure that never
#    established absence at all (rate limit, 403 token scope, 5xx). Reporting
#    the latter as "comment-absent" would send an operator hunting for a
#    missing comment that in fact exists — so each gets its own arm. Both are
#    still best-effort no-ops (exit 0); only the diagnosis differs.
#    workpad.py writes the SPECIFIC gh cause (rate limit, 403 token scope, 5xx) to
#    its own stderr, so capture it rather than 2>/dev/null-ing it away: without the
#    cause an operator staring at a frozen `🚀 Reviewing` comment cannot tell a
#    transient blip from a token-scope misconfiguration. Same intent as the stall
#    backstop's `tail -c 300 "$GH_ERRF"`, but read with bash builtins only — no
#    external `tail`/`tr`, whose absence on a stripped PATH would silently empty
#    the breadcrumb rather than surfacing an error.
WP_ERR="$(mktemp 2>/dev/null)" || WP_ERR=""
# Read+flatten $WP_ERR with builtins ($(<file), parameter expansion). Empty when the
# capture file could not be allocated — the breadcrumb then just omits the cause.
_wp_cause() {
  [ -n "$WP_ERR" ] && [ -s "$WP_ERR" ] || { printf '(cause unavailable)'; return 0; }
  local c; c="$(<"$WP_ERR")"; c="${c//$'\n'/ }"
  printf '%s' "${c: -300}"
}
_wp_err_cleanup() { [ -n "$WP_ERR" ] && rm -f "$WP_ERR"; return 0; }
CID="$(python3 "$WORKPAD" id "$PR" --marker "$MARKER" 2>"${WP_ERR:-/dev/null}")"
ID_RC=$?
if [ "$ID_RC" -eq 2 ]; then
  echo "flip-review-progress-failed: no devflow:review-progress comment for PR #${PR} (marker '${MARKER}', workpad.py id rc=2 — scanned cleanly, none present) — comment-absent no-op" >&2
  _wp_err_cleanup
  exit 0
elif [ "$ID_RC" -ne 0 ] || [ -z "$CID" ]; then
  echo "flip-review-progress-failed: could not look up PR #${PR}'s review-progress comment (marker '${MARKER}', workpad.py id rc=${ID_RC}) — read-failure no-op; the comment's absence was NOT established. Cause: $(_wp_cause)" >&2
  _wp_err_cleanup
  exit 0
fi

# 2. Read the current body (same stderr-capture discipline).
BODY="$(python3 "$WORKPAD" body "$CID" 2>"${WP_ERR:-/dev/null}")"
BODY_RC=$?
if [ "$BODY_RC" -ne 0 ] || [ -z "$BODY" ]; then
  echo "flip-review-progress-failed: could not read body of comment #${CID} for PR #${PR} (workpad.py body rc=${BODY_RC}) — read-failure no-op. Cause: $(_wp_cause)" >&2
  _wp_err_cleanup
  exit 0
fi
_wp_err_cleanup

# 3. Transform: flip the Status line ONLY when it begins with 🚀, and append a
#    one-line cause with the run link. Done in python3 (a hard dependency) so no
#    shell quoting traverses the markdown body and the 🚀 test is a literal byte
#    match, not a locale-dependent sed alternation. Prints a result token.
TMP="$(mktemp 2>/dev/null)" || {
  echo "flip-review-progress-failed: mktemp failed for PR #${PR} comment #${CID} — read/patch-failure no-op" >&2
  exit 0
}
RESULT="$(DEVFLOW_BODY="$BODY" DEVFLOW_CAUSE="$CAUSE" DEVFLOW_RUN_URL="$RUN_URL" \
  python3 - "$TMP" <<'PYEOF'
import os, re, sys
body = os.environ.get('DEVFLOW_BODY', '')
cause = os.environ.get('DEVFLOW_CAUSE', '')
run_url = os.environ.get('DEVFLOW_RUN_URL', '')
out_path = sys.argv[1]
m = re.search(r'^\*\*Status:\*\*[ \t]*(.*)$', body, re.MULTILINE)
if not m:
    print('NOSTATUS')
    sys.exit(0)
# Fail closed: flip only an interim (🚀-prefixed) Status. Anything else — a
# written verdict, an agent-side ❌ Review failed, any terminal glyph — is
# treated as terminal and left untouched.
if not m.group(1).lstrip().startswith('🚀'):
    print('TERMINAL')
    sys.exit(0)
one_line_cause = ' '.join(cause.splitlines())
new_body = body[:m.start()] + '**Status:** ❌ Review failed' + body[m.end():]
new_body = new_body.rstrip('\n') + '\n\n' + \
    f'_Review run failed: {one_line_cause} — {run_url}_\n'
with open(out_path, 'w', encoding='utf-8') as f:
    f.write(new_body)
print('FLIP')
PYEOF
)"

case "$RESULT" in
  FLIP)
    if python3 "$WORKPAD" patch "$CID" "$TMP" >/dev/null 2>&1; then
      echo "flip-review-progress-failed: flipped PR #${PR} review-progress comment #${CID} to '❌ Review failed' (${CAUSE})" >&2
    else
      echo "flip-review-progress-failed: patch of comment #${CID} for PR #${PR} failed — read/patch-failure no-op (Status left unchanged)" >&2
    fi
    ;;
  TERMINAL)
    echo "flip-review-progress-failed: PR #${PR} comment #${CID} Status is not 🚀 (already terminal) — no flip" >&2
    ;;
  NOSTATUS)
    echo "flip-review-progress-failed: PR #${PR} comment #${CID} has no Status line — no flip" >&2
    ;;
  *)
    echo "flip-review-progress-failed: transform of comment #${CID} for PR #${PR} produced no result — read/patch-failure no-op" >&2
    ;;
esac

rm -f "$TMP"
exit 0
