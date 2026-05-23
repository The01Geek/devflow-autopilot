#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# gh-stub.sh — fake `gh` for devflow tests.
# Set DEVFLOW_FIXTURE_PR to pick the fixture set (e.g. "793" or "CLEAN").
# Stubs ignore --jq, -q, --paginate; they always emit one full JSON doc per call.
FX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SET="${DEVFLOW_FIXTURE_PR:-793}"

ARGS="$*"

case "$ARGS" in
  *"repo view"*)
    echo "acme/example-repo"
    ;;
  *"pr view"*)
    cat "$FX/${SET}-prview.json"
    ;;
  *"pr diff"*)
    cat "$FX/${SET}-diff.txt"
    ;;
  *"pulls/"*"/comments"*)
    # inline review comments
    cat "$FX/${SET}-reviewcomments.json"
    ;;
  *"issues/"*"/comments"*)
    # conversation comments
    cat "$FX/${SET}-prcomments.json"
    ;;
  *"pulls/"*"/reviews"*)
    cat "$FX/${SET}-reviews.json"
    ;;
  *"pulls/"*"/commits"*)
    cat "$FX/${SET}-commits.json"
    ;;
  *"check-runs"*)
    cat "$FX/${SET}-checkruns.json" 2>/dev/null || echo '{"check_runs":[]}'
    ;;
  *"commits/"*)
    # per-commit detail (for human-postbot diff patch)
    cat "$FX/${SET}-commitpatch.json" 2>/dev/null || echo '{"files":[]}'
    ;;
  *"issues/"*)
    # gh issue view or gh api repos/.../issues/<n>
    cat "$FX/${SET}-issue.json" 2>/dev/null || echo '{}'
    ;;
  *"collaborators/alice/permission"*)
    # Alice is the known write/admin collaborator used by auth unit tests.
    echo "write"
    ;;
  *"collaborators/"*"/permission"*)
    # Any other actor is not a collaborator (returns 'none' via HTTP 404 path).
    echo "Not Found (HTTP 404)" >&2; exit 1
    ;;
  *)
    echo '[]'
    ;;
esac
