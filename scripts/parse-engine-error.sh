#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# parse-engine-error.sh — print "true" when the claude-code-action execution log
# indicates the review engine ended in error (is_error), else "false". Extracted
# out of devflow-runner.yml's "Surface review-engine execution result" step (issue
# #249) so this edge-case-prone parsing is unit-testable, exactly as the verdict
# derivation was extracted into derive-review-verdict.sh. The runner's
# engine_is_error output is this helper's stdout; finalize_check reads it as the
# ENGINE_ERROR signal (a review that ended is_error but whose JOB still reported
# success is treated as no-verdict-for-HEAD).
#
# claude-code-action@v1 writes the execution log to the file named by
# steps.claude.outputs.execution_file. Two documented shapes are parsed
# defensively:
#   - a stream-json ARRAY whose final `type=="result"` element carries is_error;
#   - a single result OBJECT carrying is_error.
# Any absent/unparseable/missing field yields "false" — the fail-safe direction:
# is_error is defense-in-depth, and finalize_check's HEAD-SHA verdict scoping
# remains the primary staleness guard (issue #249). Always exits 0 (best-effort,
# like derive-review-verdict.sh) — the caller reads stdout, not the exit code.
#
# Usage: parse-engine-error.sh [EXECUTION_FILE]
#   EXECUTION_FILE  path to the claude-code-action execution log. An empty,
#                   missing, or unreadable path yields "false".
#
# $DEVFLOW_JQ overrides the `jq` binary (the same seam the rest of devflow uses;
# honored by the sourced resolver below).

set -uo pipefail

_PEE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-jq.sh
. "$_PEE_DIR/../lib/resolve-jq.sh"  # assigns DEVFLOW_JQ

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo false
  exit 0
fi

# `// false` collapses a null/absent/false is_error (and an empty result set:
# [] | last -> null) to a literal false; a parse error routes through the
# `|| echo ""` and is likewise not "true", so IS_ERROR stays false.
PARSED=$("$DEVFLOW_JQ" -r '
  (if type == "array" then (map(select(.type == "result")) | last | .is_error)
   elif type == "object" then .is_error
   else null end) // false' "$FILE" 2>/dev/null || echo "")

if [ "$PARSED" = "true" ]; then
  echo true
else
  echo false
fi
exit 0
