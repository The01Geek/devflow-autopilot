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
#   - Emits exactly one stderr breadcrumb naming the arm it took: flipped,
#     comment-absent, status-already-terminal, or read/patch-failure.
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

if [ -z "$PR" ] || [ -z "$MARKER" ]; then
  echo "flip-review-progress-failed: usage: flip-review-progress-failed.sh <pr_number> <marker> <cause>; missing pr number or marker — no-op" >&2
  exit 0
fi

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
#    run, so a prior run's comment is never a candidate. `id` exits 2 (absent)
#    or 1 (read error) with empty stdout — both route to the comment-absent /
#    read-failure no-op, so a review with no seeded comment (flag off, non-PR
#    mode, /pr-description runs, seed failure) is handled here.
CID="$(python3 "$WORKPAD" id "$PR" --marker "$MARKER" 2>/dev/null)"
ID_RC=$?
if [ "$ID_RC" -ne 0 ] || [ -z "$CID" ]; then
  echo "flip-review-progress-failed: no devflow:review-progress comment for PR #${PR} (marker '${MARKER}', workpad.py id rc=${ID_RC}) — comment-absent no-op" >&2
  exit 0
fi

# 2. Read the current body.
BODY="$(python3 "$WORKPAD" body "$CID" 2>/dev/null)"
BODY_RC=$?
if [ "$BODY_RC" -ne 0 ] || [ -z "$BODY" ]; then
  echo "flip-review-progress-failed: could not read body of comment #${CID} for PR #${PR} (workpad.py body rc=${BODY_RC}) — read-failure no-op" >&2
  exit 0
fi

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
