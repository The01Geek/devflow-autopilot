#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-hook-probe.sh — render the AC6 Stop-hook firing observation for the
# hook-probe job's step summary (issue #437). Extracted from the workflow's inline
# shell per the repo convention that branch-selecting workflow shell composing a
# user-facing message lives in a suite-drivable scripts/ helper (PR #438 review;
# precedent: scripts/describe-denial-count.sh, PR #367) — so lib/test/run.sh can
# drive BOTH arms and their wording, not just grep-pin the marker literal.
#
# Usage: describe-hook-probe.sh <marker-path>
#   Selects on the marker file's PRESENCE — the AC6 measurement itself. The
#   did-not-fire arm carries the reverse-launder warning verbatim: a
#   "did not fire" must never be read as "hooks do not fire". The hook is on
#   base (run 29224205805 proved it fires), so an absent marker is an anomaly.
#
# Best-effort: always exits 0 (an informational renderer must not fail the probe
# job); a missing argument breadcrumbs to stderr and renders nothing.

set -uo pipefail

MARKER="${1:-}"
if [ -z "$MARKER" ]; then
  echo "devflow: describe-hook-probe.sh: no marker path argument — rendering nothing" >&2
  exit 0
fi

echo "## Stop-hook execution probe (issue #437 AC6)"
if [ -f "$MARKER" ]; then
  echo "- observed: **FIRED** — the base-branch \`.claude/settings.json\` Stop hook executed under claude-code-action (breadcrumb \`$MARKER\` present)."
else
  echo "- observed: **did not fire this run** — breadcrumb \`$MARKER\` absent."
  echo "- NOTE: the Stop hook is on the BASE branch (\`.claude/settings.json\` on the default branch), which claude-code-action restores and run \`29224205805\` proved fires — so an absent marker here is an **anomaly**, not the expected state. It means the hook could not write or the session never reached Stop, not that hooks are ineffective: the hook never ran, its \`mkdir -p\` failed, both write attempts failed, or the \`claude\` step itself failed before Stop — each leaves a distinct stderr breadcrumb in this job's log; check it for the cause. Do NOT read this as 'hooks do not fire'."
fi
exit 0
