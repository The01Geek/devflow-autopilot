#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# classify-id-exit.sh — map `workpad.py id`'s process exit code to the early-workpad
# gate's three-way handoff DISPATCH action (issue #537).
#
# Why a helper rather than an inline `if/elif` in devflow-implement.yml: this dispatch
# IS the duplicate-workpad-prevention logic the whole #537 startup-lifecycle change
# exists to make safe. A silently mis-selected arm — a reordered branch, an inverted
# `-eq 2`, a typo'd exit code — would mislabel provenance or attempt a DUPLICATE
# workpad while every presence-pin in the workflow stayed green. Inline shell inside
# YAML cannot be unit-tested; here lib/test/run.sh drives every arm directly (the
# describe-denial-count.sh / PR #367 precedent).
#
# The three `workpad.py id` outcomes map to three actions — the mapping is the sole
# create authorization, so it is deliberately exhaustive with a fail-CLOSED default:
#
#   0        found: a workpad already exists   -> `adopt`  (refresh + gate-adopted checkpoint;
#                                                            emits handoff=adopted-existing)
#   2        cleanly absent (SOLE create auth) -> `create` (create the workpad;
#                                                            emits handoff=created-current-run on success)
#   * (else) exit 1 unreadable, or a crash /   -> `skip`   (do NOT create — a duplicate workpad is
#            127 / segfault / any other code               worse than a delayed one; handoff stays unknown)
#
# The `create` action authorizes a create ONLY on exit 2 specifically; any unexpected
# code falls to `skip`, never `create`, so a transient read failure can never be
# misread as absence and duplicate a workpad. The caller (early_workpad) captures
# `id`'s exit inline (`|| id_exit=$?`) and passes it here as $1.
#
# Usage: classify-id-exit.sh [EXIT_CODE]
#   EXIT_CODE  `workpad.py id`'s process exit code (a digit string; empty/non-digit -> skip).
# Prints exactly one of `adopt` / `create` / `skip` to stdout. Always exits 0.

set -u

case "${1:-}" in
  0)
    printf '%s\n' adopt
    ;;
  2)
    printf '%s\n' create
    ;;
  *)
    printf '%s\n' skip
    ;;
esac
exit 0
