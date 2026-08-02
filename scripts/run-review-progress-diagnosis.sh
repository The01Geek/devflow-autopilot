#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# run-review-progress-diagnosis.sh COMMAND REPO PR_NUMBER EXPECTED_MARKER
#
# Workflow-facing dispatcher for issue #1054. It owns the canonical-command
# predicate so the workflow shell does not carry an untestable branch selector.
# Non-review commands are silent no-ops. Review commands invoke the sibling
# four-arm diagnosis helper and preserve its best-effort, always-zero contract.

set -uo pipefail

COMMAND="${1:-}"
REPO="${2:-}"
PR_NUMBER="${3:-}"
EXPECTED_MARKER="${4:-}"

case "$COMMAND" in
  "/prflow:review "*|"/prflow:review-and-fix "*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR=.
fi
if ! SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd)" || [ -z "$SCRIPT_DIR" ]; then
  echo "::notice::flip review-progress: could not establish marker diagnosis because the dispatcher directory is unresolved" >&2
  exit 0
fi

DIAG_HELPER="$SCRIPT_DIR/diagnose-review-progress-marker.sh"
if [ ! -r "$DIAG_HELPER" ]; then
  echo "::notice::flip review-progress: could not establish marker diagnosis because the helper is absent or unreadable at $DIAG_HELPER" >&2
  exit 0
fi

bash "$DIAG_HELPER" "$REPO" "$PR_NUMBER" "$EXPECTED_MARKER" >/dev/null
DIAG_RC=$?
if [ "$DIAG_RC" -ne 0 ]; then
  echo "::notice::flip review-progress: diagnosis helper exited $DIAG_RC unexpectedly; marker diagnosis was not established" >&2
fi
exit 0
