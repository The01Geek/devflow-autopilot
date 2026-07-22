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
#   EFFORT_SUPPORTED    provider effort capability (unset -> true; explicit empty/non-enum
#                       -> false, failing closed to the honest fallback — #700 S1)
#   DEVFLOW_RRO         resolver path override (default: vendored, else self-repo)
#   DEVFLOW_AE_SIDECAR  sidecar output path (default: repo-root-anchored
#                       .devflow/tmp/agent-effort-applied.json — mirrors the recorder, #700 S2)
#   DEVFLOW_AE_CONFIG   trusted config FILE threaded as --config to the resolver (#700 B1);
#                       set to the BASE-ref config on the read-only review tier, unset on the
#                       implement/command tiers (which read their own trusted working tree)

set -uo pipefail

# "Unknown is not zero" (#700 S1): an UNSET capability falls back to the documented
# default (true — the Anthropic path, where the model-level Haiku gate still applies), but
# an EXPLICIT empty value (a provider step whose effort_supported output was empty —
# capability undetermined) must NOT be rewritten to true and recorded as an applied claim.
# `-` (not `:-`) so an explicit empty survives the default, then any non-enum value (empty
# included) is pinned to false, failing closed to the honest fallback.
EFFORT_SUPPORTED="${EFFORT_SUPPORTED-true}"
case "$EFFORT_SUPPORTED" in
  true|false) : ;;
  *) EFFORT_SUPPORTED=false ;;
esac
# Sidecar default is REPO-ROOT-anchored (#700 S2), byte-for-byte the recorder's rule in
# lib/efficiency-trace.sh (`$(devflow_repo_root)/.devflow/tmp/agent-effort-applied.json`),
# so applier and recorder resolve the SAME path regardless of cwd — a `working-directory:`
# or subdir invocation no longer makes the composer write path A while the recorder reads
# path B. Anchored inline via git (config-source.sh's own devflow_repo_root rule) rather
# than by sourcing config-source.sh, whose `set -e` would break this helper's fail-open
# contract. Coupling pinned in lib/test/run.sh.
SIDECAR="${DEVFLOW_AE_SIDECAR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.devflow/tmp/agent-effort-applied.json}"

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

# Trusted config source (#700 B1). On the READ-ONLY review tier the caller sets
# DEVFLOW_AE_CONFIG to the BASE-ref config file (materialized by baseprovision), so the
# per-agent effort overrides resolve from the maintainer-controlled base ref — a PR author
# cannot steer the merge-gating reviewer's reasoning effort of their own PR via head
# config, mirroring the sibling provider/effort steps' base-ref discipline. Unset/empty →
# the resolver reads the working-tree config, legitimate on the implement/command tiers
# which operate on their own trusted tree. A set-but-MISSING path resolves to NO overrides
# (config-get.sh returns empty for an explicit absent file), never a working-tree fallback
# — so the review tier fails closed to the honest fallback even if materialization failed.
# The `${arr[@]+…}` expansion is the bash-3.2-safe empty-array form under `set -u`.
AE_CONFIG_ARGS=()
if [ -n "${DEVFLOW_AE_CONFIG:-}" ]; then
  AE_CONFIG_ARGS=(--config "$DEVFLOW_AE_CONFIG")
fi

# 3. Compose the startup --agents map and validate it is a non-empty JSON object (#700 #5).
AGENTS_JSON="$(python3 "$RRO" --known-roster --effort-supported "$EFFORT_SUPPORTED" "${AE_CONFIG_ARGS[@]+"${AE_CONFIG_ARGS[@]}"}" --applied-agents-json 2>/dev/null || true)"
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
#    DEFERRED (#700 finding #7 — "consider a single combined emit"): this is a SECOND,
#    independent resolver process — not one gate pass reused. It is not merged into one
#    emit because each call runs its OWN build_applied_effort gate pass over identical
#    inputs (--known-roster, the same --effort-supported and --config), and that gate is
#    deterministic, so the two separate calls cannot disagree; a combined `--applied-*-json`
#    mode is a CLI-contract change with churn but no correctness gain. Revisit only if the
#    resolver's applied output ever becomes non-deterministic.
mkdir -p "$(dirname "$SIDECAR")" 2>/dev/null || true
if python3 "$RRO" --known-roster --effort-supported "$EFFORT_SUPPORTED" "${AE_CONFIG_ARGS[@]+"${AE_CONFIG_ARGS[@]}"}" --applied-sidecar-json > "$SIDECAR" 2>/dev/null; then
  printf '%s\n' "--agents '$AGENTS_JSON'"
else
  rm -f "$SIDECAR"
  printf '%s\n' ""
fi
exit 0
