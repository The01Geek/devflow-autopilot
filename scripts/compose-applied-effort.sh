#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# compose-applied-effort.sh — compose the applied per-agent effort `--agents` splice
# and the applier->recorder sidecar for the SEAM_PROVEN cloud seam (issue #669).
#
# Extracted from the triplicated workflow composer step (issue #700 finding #4) so the
# suite can drive each branch directly: the step has real branch logic (resolver-absent
# fail-open, empty/`{}` short-circuit, sidecar write-then-fallback), and a grep-pin on a
# message literal is not coverage of the selection that chooses it (CLAUDE.md
# best-effort-parser rule; reference sibling: scripts/describe-denial-count.sh).
#
# Prints the `agents_args` VALUE to stdout: `--agents '<json>'` when a capability-gated
# per-agent effort is composed, else the empty string. Manages the applier->recorder
# sidecar file. ALWAYS exits 0 (fail-open to the honest fallback — never a false applied
# claim, never a hard abort that would break the launch).
#
# Behavior, in order:
#   1. Unconditionally remove any pre-existing sidecar (issue #700 finding #3): a stale
#      sidecar left by a prior run on a reused workspace (self-hosted runners are not
#      cleaned by default) would otherwise be read by the in-session recorder as fabricated
#      `application_point: agent-definition` telemetry. Clearing it up front — BEFORE the
#      resolver gate — means a run that applies NOTHING leaves no sidecar.
#   2. Resolve the resolver (vendored path, else self-repo). Missing → print empty, exit 0
#      (a run before the plugin is vendored fails open to the honest fallback).
#   3. Ask the resolver for the startup `--agents` agent-definition map and VALIDATE it is a
#      non-empty JSON object (issue #700 finding #5): a resolver failure, or non-object,
#      empty, `{}`, or partial-then-nonzero output, all fall through to the honest fallback
#      — never concatenated onto a fallback and spliced into `--agents` unvalidated.
#   4. Write the applier->recorder sidecar (a second resolver pass, post-capability-gate)
#      FIRST, and emit the `--agents` splice ONLY if that write succeeded, so applied ⟺
#      recorded stays invariant (the split-brain build_applied_effort avoids by returning
#      both from one gate pass). A failed sidecar write degrades this run to the honest
#      fallback — never applied-but-unrecorded (issue #700 finding #4's false-negative path).
#
# The emitted JSON keys are fixed KNOWN_AGENTS ids and values are enum efforts (the
# resolver validates against the enum and applies the capability gate), so it carries no
# single quotes — safe to single-quote as one CLI token spliced into claude_args.
#
# Env (overridable for tests):
#   EFFORT_SUPPORTED    provider effort capability (default true)
#   DEVFLOW_RRO         resolver path override (default: vendored, else self-repo)
#   DEVFLOW_AE_SIDECAR  sidecar output path (default .devflow/tmp/agent-effort-applied.json)

set -uo pipefail

EFFORT_SUPPORTED="${EFFORT_SUPPORTED:-true}"
SIDECAR="${DEVFLOW_AE_SIDECAR:-.devflow/tmp/agent-effort-applied.json}"

# 1. Unconditional stale-sidecar clear (#700 #3) — before the resolver gate, so a run
#    that applies nothing never leaves a sidecar a later recorder would over-trust.
rm -f "$SIDECAR"

# 2. Resolve the resolver.
RRO="${DEVFLOW_RRO:-}"
if [ -z "$RRO" ]; then
  RRO=.devflow/vendor/devflow/scripts/resolve-review-overrides.py
  [ -f "$RRO" ] || RRO=scripts/resolve-review-overrides.py
fi
if [ ! -f "$RRO" ]; then
  printf '%s\n' ""
  exit 0
fi

# 3. Compose the startup --agents map and validate it is a non-empty JSON object (#700 #5).
AGENTS_JSON="$(python3 "$RRO" --known-roster --effort-supported "$EFFORT_SUPPORTED" --applied-agents-json 2>/dev/null || true)"
if ! printf '%s' "$AGENTS_JSON" | python3 -c 'import json,sys
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(obj, dict) and obj else 1)' 2>/dev/null; then
  printf '%s\n' ""
  exit 0
fi

# 4. Write the applier->recorder sidecar FIRST; emit the splice only if it was written,
#    so applied ⟺ recorded (#700 #4). A failed write degrades to the honest fallback.
#    DEFERRED (#700 finding #7 — "consider a single combined emit"): the sidecar is a
#    SECOND resolver invocation. Not merged into one emit because both maps derive from the
#    same build_applied_effort gate pass over identical inputs (--known-roster, same
#    --effort-supported), so the two deterministic calls cannot disagree; a combined
#    `--applied-*-json` mode is a CLI-contract change with churn but no correctness gain.
#    Revisit only if the resolver's applied output ever becomes non-deterministic.
mkdir -p "$(dirname "$SIDECAR")" 2>/dev/null || true
if python3 "$RRO" --known-roster --effort-supported "$EFFORT_SUPPORTED" --applied-sidecar-json > "$SIDECAR" 2>/dev/null; then
  printf '%s\n' "--agents '$AGENTS_JSON'"
else
  rm -f "$SIDECAR"
  printf '%s\n' ""
fi
exit 0
