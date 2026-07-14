#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# collect-staged-telemetry.sh <repo_root> <dest>
#
# The upload-side (PR-head, read-only review tier) half of the telemetry relay (issue #489, AC2).
# Consolidate every staged telemetry subtree — <repo_root>/.devflow/tmp/telemetry-stage-*/.devflow/logs
# (left in place by lib/efficiency-trace.sh's staging-only `--persist`) — into <dest>/.devflow/logs,
# preserving the `.devflow/logs/…`-relative paths, so the caller can upload <dest> as one workflow
# artifact for the trusted pusher to download.
#
# Extracted from the workflow's inline shell so lib/test/run.sh can drive it (the repo's
# inline-shell-extraction convention). This collection is BEST-EFFORT: the trusted pusher
# re-validates every entry all-or-nothing (scripts/validate-telemetry-artifact.sh), so a miss
# here can never let an unadmitted path reach the branch — it only affects what is uploaded.
#
# stdout: prints `1` when at least one staged tree was collected (the caller's "something to
# upload" signal), otherwise nothing. Always exits 0 (best-effort).

set -uo pipefail

ROOT="${1:-}"
DEST="${2:-}"
if [ -z "$ROOT" ] || [ -z "$DEST" ]; then
  echo "collect-staged-telemetry: usage: collect-staged-telemetry.sh <repo_root> <dest>" >&2
  exit 0
fi

rm -rf "$DEST" 2>/dev/null || true
mkdir -p "$DEST" || { echo "::warning::collect-staged-telemetry: could not create dest '$DEST'; nothing collected" >&2; exit 0; }

found=
for stage in "$ROOT"/.devflow/tmp/telemetry-stage-*/; do
  [ -d "$stage" ] || continue                 # unmatched glob: the literal path is not a dir
  [ -d "${stage}.devflow/logs" ] || continue  # a staging root that produced no records
  # Merge this stage's .devflow/logs subtree into the consolidated dest (records from multiple
  # retained staging roots land under one tree; same-named files simply overwrite).
  if mkdir -p "$DEST/.devflow/logs" && cp -R "${stage}.devflow/logs/." "$DEST/.devflow/logs/"; then
    found=1
  else
    echo "::warning::collect-staged-telemetry: failed to copy '${stage}.devflow/logs' into the upload tree (best-effort; skipping)" >&2
  fi
done

[ -n "$found" ] && printf '1\n'
exit 0
