#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# telemetry-push-artifact.sh <artifact_dir> <repo_root>
#
# The trusted-side orchestration for the cross-workflow telemetry relay (issue #489, AC3).
# Invoked by `.github/workflows/telemetry-push.yml` — a job triggered via `workflow_run`
# off the auto-review workflow's completion, running in the TRUSTED context (default-branch
# code, a write-capable App token) and NEVER checking out the PR head. It:
#   1. Validates <artifact_dir> (the downloaded, PR-head-produced, UNTRUSTED workflow
#      artifact) all-or-nothing via scripts/validate-telemetry-artifact.sh. A violating
#      artifact is dropped WHOLE (the validator emits a ::warning::) and nothing is pushed.
#   2. On a clean, non-empty validated tree, reuses lib/telemetry-branch.sh's existing
#      CAS-ref-advance / verify-store / bounded-fetch-and-push write path
#      (devflow_telemetry_persist_tree) — with DEVFLOW_TELEMETRY_PUSH=1 so the writable
#      tier actually pushes — to land the records on `devflow-telemetry`. No push is
#      re-implemented here.
#
# Intermediate-inert contract (issue #489 landing-order): an ABSENT, EMPTY, or fully-dropped
# artifact pushes NOTHING and says so — exit 0. The pusher never fails the run red on a
# hostile artifact (that is a dropped-with-::warning:: event, not an error).
#
# stderr carries the breadcrumbs; exit 0 = pushed / clean no-op / dropped-whole / nothing
# to push; exit 1 = usage error or an unrecoverable environment/source failure (the trusted
# job MUST fail loud rather than silently drop telemetry via a no-op stub).

set -uo pipefail

ARTIFACT_DIR="${1:-}"
REPO_ROOT="${2:-}"

if [ -z "$ARTIFACT_DIR" ] || [ -z "$REPO_ROOT" ]; then
  echo "::error::telemetry-push-artifact: usage: telemetry-push-artifact.sh <artifact_dir> <repo_root>" >&2
  exit 1
fi
if [ ! -d "$REPO_ROOT/.git" ] && [ ! -f "$REPO_ROOT/.git" ]; then
  echo "::error::telemetry-push-artifact: repo_root '$REPO_ROOT' is not a git working tree — the trusted pusher must run against a checkout" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"

# Build a validated staging root OUTSIDE the repo tree so it never dirties the checkout.
# mktemp is avoided (matches the repo's telemetry idiom) — a unique dir from bash builtins.
STAGE_BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
VALIDATED_ROOT="$STAGE_BASE/devflow-telemetry-validated-$(date -u +%Y%m%d%H%M%S 2>/dev/null || printf '00000000000000')-$$-${RANDOM}"
rm -rf "$VALIDATED_ROOT" 2>/dev/null || true
mkdir -p "$VALIDATED_ROOT" || { echo "::error::telemetry-push-artifact: could not create the validated staging root '$VALIDATED_ROOT'" >&2; exit 1; }
# Clean up the transient staging tree on every exit path.
trap 'rm -rf "$VALIDATED_ROOT" 2>/dev/null || true' EXIT

# Step 1 — validate (all-or-nothing). A non-zero exit means the artifact was DROPPED whole
# (the validator already emitted the ::warning::). Push nothing; exit 0 (best-effort).
if ! "$HERE/validate-telemetry-artifact.sh" "$ARTIFACT_DIR" "$VALIDATED_ROOT"; then
  echo "::notice::telemetry-push-artifact: the downloaded artifact was dropped by validation — nothing pushed to the telemetry branch this run." >&2
  exit 0
fi

# An admitted-but-empty result (absent/empty artifact) → nothing to push; say so.
# The validator only materializes the `.devflow/logs/…` subtree when it admits at least
# one record, so its presence is the builtin emptiness probe (no non-preflight PATH tool).
if [ ! -d "$VALIDATED_ROOT/.devflow/logs" ]; then
  echo "::notice::telemetry-push-artifact: no telemetry records to push (the artifact was absent, empty, or contained no admitted records)." >&2
  exit 0
fi

# Step 2 — push via the existing telemetry-branch write path. Source the lib; FAIL LOUD on
# a source failure (unlike efficiency-trace.sh's no-op-stub degrade — a stub would silently
# drop telemetry in this trusted writer, defeating the relay's whole purpose).
# shellcheck source=../lib/resolve-jq.sh
. "$LIB_DIR/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
# shellcheck source=../lib/config-source.sh
. "$LIB_DIR/config-source.sh" \
  || { echo "::error::telemetry-push-artifact: could not source lib/config-source.sh — cannot resolve the telemetry branch; refusing to silently drop telemetry" >&2; exit 1; }
# shellcheck source=../lib/telemetry-branch.sh
. "$LIB_DIR/telemetry-branch.sh" \
  || { echo "::error::telemetry-push-artifact: could not source lib/telemetry-branch.sh — the telemetry write path is unavailable; refusing to silently drop telemetry" >&2; exit 1; }

# The affirmative push operand: this IS the trusted, contents:write tier the staging-only
# review tier deferred to. Without it, devflow_telemetry_persist_tree returns 2 (staging-only)
# and the records would never land.
export DEVFLOW_TELEMETRY_PUSH=1

# Reuse the shared write path (CAS ref-advance / verify-store / bounded fetch-and-push).
# Its return code (0 clean/pushed, 1 degraded-but-non-fatal, 2 staging-only) is best-effort;
# 2 should not occur here because DEVFLOW_TELEMETRY_PUSH=1 is set, but a 2 still means nothing
# was pushed, so surface it and still exit 0 (best-effort — the run is not red).
devflow_telemetry_persist_tree "$REPO_ROOT" "$VALIDATED_ROOT"
rc=$?
case "$rc" in
  0) echo "::notice::telemetry-push-artifact: telemetry records persisted to the branch (or already present — idempotent no-op)." >&2 ;;
  1) echo "::warning::telemetry-push-artifact: telemetry push degraded (see the telemetry-branch breadcrumb above); records not landed this run." >&2 ;;
  2) echo "::warning::telemetry-push-artifact: telemetry-branch reported staging-only despite DEVFLOW_TELEMETRY_PUSH=1 — nothing pushed (unexpected)." >&2 ;;
  *) echo "::warning::telemetry-push-artifact: telemetry-branch returned an unexpected code $rc — nothing assumed pushed." >&2 ;;
esac
exit 0
