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
#      FIRST, and emit the `--agents` splice ONLY if that pass produced a usable map AND
#      the write succeeded, so applied implies recorded (the split-brain avoided INSIDE
#      `build_applied_effort`, which returns both maps from one gate pass; this shell
#      composer runs the resolver twice, so it re-validates rather than inheriting that
#      guarantee). A failed or empty sidecar pass degrades this run to the honest
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
#    CHECKED (#700 review, F15): `rm -f` suppresses the not-found error but still returns
#    nonzero on a REAL removal failure (read-only mount, immutable file, unwritable dir).
#    Proceeding past that would leave a sidecar of unknown provenance on disk while this
#    run applies nothing — precisely the fabricated `agent-definition` telemetry the clear
#    exists to prevent — so refuse to apply rather than continue with it surviving.
if ! rm -f "$SIDECAR" 2>/dev/null && [ -e "$SIDECAR" ]; then
  printf 'compose-applied-effort: could not clear the stale sidecar %s; refusing to apply (a surviving stale sidecar would be recorded as applied effort this run never emitted)\n' "$SIDECAR" >&2
  printf '%s\n' ""
  exit 0
fi

# 1b. APPLY GATE — default OFF (#700 review, F1: the seam shape is NOT spike-proven).
# The `agents-seam-probe` spike proved a fully-defined NEW agent
# (`{"seam-probe-agent":{"description":…,"prompt":…,"effort":"low"}}`) is forwarded and
# governs. This composer emits something structurally DIFFERENT: an effort-only entry
# keyed by an ALREADY-INSTALLED plugin agent id containing a colon
# (`{"devflow:code-reviewer":{"effort":"low"}}`). Nothing measured establishes that such
# an entry PATCHES the installed agent rather than DEFINING/SHADOWING it, nor that a
# definition lacking `description`/`prompt` validates at all. The blast radius is not
# hypothetical: under this repo's own `agent_overrides.default.effort` every non-Haiku
# member of the roster gets an entry, so if `--agents` shadows, every merge-gating review
# agent silently degrades to a prompt-less stub on every cloud run.
#
# So AC1 (the APPLICATION half) is deferred until a probe row measures THIS shape, while
# AC2 (the telemetry half — build_applied_effort, the sidecar contract, the recorder, and
# their tests) ships. With the gate off this helper composes NOTHING and writes NO
# sidecar: emitting a sidecar for an effort that was never spliced into `claude_args`
# would make `application_point: agent-definition` and `effective` false claims, the exact
# unearned-applied-value defect the AC2 contract forbids. Flip DEVFLOW_AE_APPLY=1 (and
# restore the `claude_args` splice) once the probe records the shape as proven.
if [ "${DEVFLOW_AE_APPLY:-0}" != "1" ]; then
  printf 'compose-applied-effort: applied arm inert (DEVFLOW_AE_APPLY not set) — the effort-only/installed-agent-id `--agents` shape is not spike-proven; honest fallback stands, no sidecar written\n' >&2
  printf '%s\n' ""
  exit 0
fi

# 2. Resolve the resolver.
RRO="${DEVFLOW_RRO:-}"
if [ -z "$RRO" ]; then
  RRO=.devflow/vendor/devflow/scripts/resolve-review-overrides.py
  [ -f "$RRO" ] || RRO=scripts/resolve-review-overrides.py
fi
if [ ! -f "$RRO" ]; then
  # Breadcrumb (#700 review, F8): every fail-open path names its cause on stderr, matching
  # this repo's best-effort-helper contract (lib/resolve-bin.sh, scripts/ensure-label.sh,
  # scripts/apply-labels.sh, lib/normalize-path.sh all pair always-exit-0 with a
  # breadcrumb). Silent fail-open is indistinguishable from "nothing configured", which is
  # exactly the #502 vendor-skew state an operator most needs to diagnose.
  printf 'compose-applied-effort: resolver not found at the vendored or self-repo path (%s); no per-agent effort applied (honest fallback)\n' "$RRO" >&2
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
# stderr is deliberately NOT suppressed (#700 review, F9): the resolver's own
# unknown-agent-drift and config-shape warnings are the only channel naming a diagnosable
# cause, and its comment says it warns "so it isn't a silent no-op". This helper is that
# resolver's only production caller, so routing its stderr to /dev/null would make the
# warning path dead in the deployed configuration. Only stdout is captured, so stderr
# reaches the workflow log without corrupting the composed value.
AGENTS_JSON="$(python3 "$RRO" --known-roster --effort-supported "$EFFORT_SUPPORTED" "${AE_CONFIG_ARGS[@]+"${AE_CONFIG_ARGS[@]}"}" --applied-agents-json || true)"
if ! printf '%s' "$AGENTS_JSON" | python3 -c 'import json,sys
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(obj, dict) and obj else 1)' 2>/dev/null; then
  printf 'compose-applied-effort: resolver produced no usable per-agent effort (absent, empty, `{}`, or a non-object) — no per-agent effort applied (honest fallback)\n' >&2
  printf '%s\n' ""
  exit 0
fi

# 4. Write the applier->recorder sidecar FIRST; emit the splice only if it was written,
#    so applied ⟺ recorded (#700 #4). A failed write degrades to the honest fallback.
#    DEFERRED (#700 finding #7 — "consider a single combined emit"): this is a SECOND,
#    independent resolver process — not one gate pass reused. It is not merged into one
#    emit because each call runs its OWN build_applied_effort gate pass over identical
#    inputs (--known-roster, the same --effort-supported and --config), and that gate is a
#    pure function of those inputs, so for a FIXED config the two calls agree. That is a
#    weaker guarantee than `build_applied_effort`'s own single-pass one — the two processes
#    each re-read the config from disk, so a config changing between them could diverge —
#    which is why BOTH passes' outputs are now validated independently above rather than
#    the second inheriting the first's result. A combined `--applied-*-json` mode remains a
#    CLI-contract change with churn but no correctness gain.
#    The sidecar pass's OUTPUT is validated too, not merely its exit status (#700 review,
#    F12): emitting the splice on exit status alone left the asymmetric hole where a pass
#    that exits 0 with empty/`{}` stdout yields a sidecar the recorder reads as `{}` while
#    `--agents` WAS applied — applied-but-unrecorded, the very invariant this ordering
#    exists to hold. Validate both passes the same way.
mkdir -p "$(dirname "$SIDECAR")" 2>/dev/null || true
SIDECAR_JSON="$(python3 "$RRO" --known-roster --effort-supported "$EFFORT_SUPPORTED" "${AE_CONFIG_ARGS[@]+"${AE_CONFIG_ARGS[@]}"}" --applied-sidecar-json || true)"
if ! printf '%s' "$SIDECAR_JSON" | python3 -c 'import json,sys
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(obj, dict) and obj else 1)' 2>/dev/null; then
  rm -f "$SIDECAR"
  printf 'compose-applied-effort: sidecar pass produced no usable map (absent, empty, `{}`, or a non-object); refusing to emit the --agents splice so applied never exceeds recorded — honest fallback\n' >&2
  printf '%s\n' ""
  exit 0
fi
if printf '%s\n' "$SIDECAR_JSON" > "$SIDECAR" 2>/dev/null; then
  printf '%s\n' "--agents '$AGENTS_JSON'"
else
  rm -f "$SIDECAR"
  printf 'compose-applied-effort: could not write the applier->recorder sidecar at %s; degrading to the honest fallback rather than applying an effort no recorder would see\n' "$SIDECAR" >&2
  printf '%s\n' ""
fi
exit 0
