#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# seed-review-progress.sh PR_NUMBER MARKER BODY_FILE — find-or-create the review
# engine's per-run live-progress comment, and print exactly one token line naming
# the outcome (issue #857).
#
# WHY A HELPER, not an inline fence (issue #857): the review engine's old seed was a
# `case` + `if`/`elif` compound in skills/review/SKILL.md carrying three screens
# (S1/S2/S3). The cloud review matcher refuses that compound outright — measured 8/8
# refusals across 6 PRs — so the screens never ran in cloud: the seed silently failed,
# `$WP` was never set, and the engine either lost the live comment entirely or
# improvised a shape that sometimes reached the `create` arm unable to tell a clean
# absence (cmd_id's silent exit 2) from an interpreter-level exit 2 — the exact
# duplicate-workpad failure issue #384 exists to prevent. Moving the find-or-create
# decision into this helper lets it run as a single-statement, leading-token
# invocation the matcher permits, and lets lib/test/run.sh drive every screen as
# ordinary shell (the same pattern as classify-id-exit.sh / describe-denial-count.sh).
#
# CONTRACT — exactly one stdout token line per reachable path, closed set, no silent
# path (a fence that prints NOTHING is therefore a harness refusal the caller routes
# to its fallback arm, never read as a create authorization):
#
#   stdout                     exit  meaning
#   RESUME <comment-id>        0     this run's comment already exists (cmd_id exit 0)
#   CREATED <comment-id>       0     clean absence confirmed; comment created
#   SKIP not-numeric          3     S1 refused a non-numeric PR number
#   SKIP workpad-unreadable   3     S2 found workpad.py missing or unreadable
#   SKIP api-error            3     S3 rejected the create arm, or `id` reported a real failure
#
# This mirrors the token-line-plus-exit-code contract the implement tier's early
# workpad gate uses, but with its OWN codes: 0 for both success tokens and 3 for every
# SKIP (the implement helper distinguishes CREATE(2) from REFUSED(3); these are read as
# separate contracts).
#
# The three screens keep the create arm reachable ONLY from cmd_id's own clean-absence
# exit:
#   (S1) A non-numeric PR number is refused BEFORE the id call, so argparse's own exit 2
#        (`id` declares `issue` as type=int) can never reach the arm split.
#   (S2) The workpad.py this helper would exec is verified readable, so python3's own
#        exit 2 on a missing ([Errno 2]) / unreadable ([Errno 13]) script can never be
#        misread as a clean absence.
#   (S3) cmd_id exits 2 SILENTLY (sys.exit(2)); every interpreter-level exit 2 writes a
#        diagnostic. So exit 2 with a NON-EMPTY captured stderr file is never a clean
#        scan — it routes to SKIP api-error, never create. Emptiness is derived with
#        `[ -s <file> ]` alone; no arm-selection value is derived through cat/tr/sed/
#        wc/cut/head (a value that decides an arm must not flow through a
#        non-preflight-guaranteed PATH tool).
#
# Usage: seed-review-progress.sh PR_NUMBER MARKER BODY_FILE
set -uo pipefail

PR_NUMBER="${1:-}"
MARKER="${2:-}"
BODY_FILE="${3:-}"

# The workpad.py this helper drives lives beside it in scripts/. S2 screens THIS path.
WORKPAD_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workpad.py"

# (S1) Refuse an empty or non-digit PR number before the id call. The `case` glob is a
# bash builtin (no PATH tool), so the screen holds even on a stripped-down host.
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "devflow review-seed: PR number '$PR_NUMBER' is not numeric — refusing the workpad.py id call (argparse would exit 2, indistinguishable from cmd_id's clean-absence exit 2)" >&2
    echo "SKIP not-numeric"
    exit 3 ;;
esac

# (S2) The workpad.py about to exec must be a readable file; otherwise python3's own
# exit 2 ([Errno 2] missing / [Errno 13] unreadable) would be misread as a clean absence.
if [ ! -r "$WORKPAD_PY" ]; then
  if [ -e "$WORKPAD_PY" ]; then
    echo "devflow review-seed: workpad.py present but unreadable ([Errno 13]) at $WORKPAD_PY — a permission-broken deploy" >&2
  else
    echo "devflow review-seed: workpad.py not present ([Errno 2]) at $WORKPAD_PY — a partial deploy" >&2
  fi
  echo "SKIP workpad-unreadable"
  exit 3
fi

# (S3) Capture id's stderr to a file (never /dev/null) so exit 2 can be split by
# emptiness. Clean up on exit.
ERRF="$(mktemp 2>/dev/null)" || ERRF=""
if [ -z "$ERRF" ]; then
  echo "devflow review-seed: could not create a scratch file for the id stderr capture" >&2
  echo "SKIP api-error"
  exit 3
fi
trap 'rm -f "$ERRF"' EXIT

# Branch on the id call's OWN exit status inline. A captured rc read in a LATER
# statement is dropped by some inline-bash runners (issue #284) — but this helper runs
# under its own shebang bash, so the concern is moot here; the inline form is kept for
# clarity and parity with the implement gate.
if WP="$("$WORKPAD_PY" id "$PR_NUMBER" --marker "$MARKER" 2>"$ERRF")"; then
  # exit 0 — this run's comment already exists.
  echo "RESUME $WP"
  exit 0
elif [ "$?" -eq 2 ] && [ ! -s "$ERRF" ]; then
  # exit 2 AND silent ⇒ cmd_id's clean absence. This run's first write: create it. The
  # marker is the body file's first line, so `create` needs no --marker.
  if WP="$("$WORKPAD_PY" create "$PR_NUMBER" "$BODY_FILE" 2>>"$ERRF")"; then
    echo "CREATED $WP"
    exit 0
  fi
  echo "devflow review-seed: workpad.py create failed after a confirmed clean absence" >&2
  echo "SKIP api-error"
  exit 3
else
  # A real gh-api/parse failure (exit 1), or exit 2 WITH stderr (an interpreter-level
  # exit, not cmd_id's clean scan). Skip to avoid a duplicate comment.
  echo "devflow review-seed: workpad.py id failed (exit != 0, or exit 2 with non-empty stderr — an interpreter-level exit, not cmd_id's clean scan)" >&2
  echo "SKIP api-error"
  exit 3
fi
