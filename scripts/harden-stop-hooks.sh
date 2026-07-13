#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# harden-stop-hooks.sh — the review runner's Stop-hook trusted-source floor (issue #458).
#
# SIBLING of scripts/filter-runner-tools.sh, applied to the Stop-hook channel the
# deny-floor's tool-permission machinery cannot reach. .claude/settings.json wires
# three `Stop` hook commands — `bash lib/efficiency-trace.sh --persist`,
# `bash lib/implement-stop-guard.sh`, and `bash …/scripts/stop-hook-probe.sh`. Under
# claude-code-action the hook CONFIGURATION is restored from the base branch
# (trusted), but the SCRIPT FILES those commands exec live under lib/ and scripts/,
# NOT under .claude/, so in the review job (.github/workflows/devflow-runner.yml
# checks out ref = the PR HEAD) they are supplied by the PR-author-editable checkout.
# A PR that edits any of those three targets would otherwise obtain unmediated shell
# execution at session end inside a secrets-bearing CI job — bypassing the #363 head
# extractor, the #401 shape rules, and the #402 tree-mutation deny-floor entirely
# (the #404 REJECT class: "the review job checks out the PR head, so a checked-out
# copy is PR-author-editable, and a floor the PR controls is no floor").
#
# This helper closes that channel the SAME way the deny-floor closes the tool channel:
# before claude-code-action runs, each Stop-hook target in the PR-head workspace is
# OVERWRITTEN with a TRUSTED copy (the base-ref content the workflow materialized into
# TRUSTED_DIR), and when no trusted copy exists for a target it is overwritten with a
# fail-closed no-op stub — NEVER left as the PR-head copy. So the executed script is
# either the base-branch version or a stub that does nothing; the PR-head version never
# runs. (An unedited PR yields byte-identical base copies, so no working-tree delta.)
#
# TRUST NOTE (mirrors filter-runner-tools.sh): a hand-edit to THIS file changes nothing
# about how the editing PR's own review is hardened — devflow-runner.yml executes this
# helper ONLY from a trusted source (a base-ref materialized copy, or the vendored copy
# gated on vendor_source=fetch), never from the PR-head checkout. The edit takes effect
# only after it lands on the base branch.
#
# Why a helper rather than an inline loop in the workflow YAML: the installer IS a
# security boundary, so a regression (a target dropped from the list, the fail-closed
# arm installing the PR-head copy instead of a stub) must fail the suite. Inline shell
# in YAML cannot be unit-tested; here lib/test/run.sh drives the full adversarial matrix
# directly. The workflow fails closed (inline no-op stubs for every target) when it
# cannot resolve a trusted copy of this helper.
#
# I/O contract:
#   input  : env WORKSPACE_ROOT (repo root of the PR-head checkout to harden; default '.')
#            env TRUSTED_DIR     (dir holding base-ref copies at the same relative subpaths,
#                                 e.g. $TRUSTED_DIR/lib/implement-stop-guard.sh; may be empty
#                                 or absent — then EVERY target is stubbed, fail-closed).
#   effect : each hook target under WORKSPACE_ROOT is replaced by its trusted copy when
#            present in TRUSTED_DIR, else by a no-op `exit 0` stub. Always chmod +x.
#   stderr : one breadcrumb line per target naming the source used (trusted | stub).
#   exit   : always 0 (best-effort — a single unwritable target must not abort the review;
#            a target that cannot be written at all is breadcrumbed but never left as the
#            PR-head copy that this helper exists to displace, because the copy/stub write
#            is attempted before anything and a failure is reported, not silently skipped).
#
# HOOK_TARGETS is the authoritative mirror of the three .claude/settings.json Stop-hook
# script paths (COUPLED — a target added there must be added here, pinned in lib/test/run.sh).

set -u

# The three Stop-hook script targets from .claude/settings.json (repo-relative).
HOOK_TARGETS='lib/efficiency-trace.sh lib/implement-stop-guard.sh scripts/stop-hook-probe.sh'

WORKSPACE_ROOT="${WORKSPACE_ROOT:-.}"
TRUSTED_DIR="${TRUSTED_DIR:-}"

# Fail-closed no-op stub: a Stop hook that does nothing rather than the PR-head copy.
STUB=$'#!/usr/bin/env bash\n# Installed by scripts/harden-stop-hooks.sh (#458): no trusted base copy of this\n# Stop-hook target was available, so it is neutralized rather than run from the\n# PR-head checkout. Fail-closed: run no hook, never a PR-controlled one.\nexit 0'

for t in $HOOK_TARGETS; do
  dest="$WORKSPACE_ROOT/$t"
  destdir="${dest%/*}"
  src="$TRUSTED_DIR/$t"

  if [ -n "$TRUSTED_DIR" ] && [ -f "$src" ]; then
    if mkdir -p "$destdir" 2>/dev/null && cp "$src" "$dest" 2>/dev/null; then
      chmod +x "$dest" 2>/dev/null || true
      printf 'devflow: harden-stop-hooks: %s <- trusted base copy\n' "$t" >&2
      continue
    fi
    printf 'devflow: harden-stop-hooks: %s — trusted copy exists but could not be installed; installing fail-closed stub instead\n' "$t" >&2
  fi

  # No trusted copy (or its install failed): fail closed to a no-op stub. NEVER leave
  # the PR-head copy in place — that is the whole exposure this helper removes.
  if mkdir -p "$destdir" 2>/dev/null && printf '%s\n' "$STUB" > "$dest" 2>/dev/null; then
    chmod +x "$dest" 2>/dev/null || true
    printf 'devflow: harden-stop-hooks: %s <- fail-closed no-op stub (no trusted base copy)\n' "$t" >&2
  else
    printf 'devflow: harden-stop-hooks: %s — could NOT write a stub (unwritable path); the PR-head copy may remain — inspect the runner\n' "$t" >&2
  fi
done

exit 0
