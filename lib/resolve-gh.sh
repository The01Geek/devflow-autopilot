#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-gh.sh — the SINGLE source of truth for DevFlow's GitHub-CLI (`gh`)
# selection contract, sourced by lib/preflight.sh and every gh-calling shell
# helper. The direct sibling of lib/resolve-python.sh, applying the same
# detect-and-verify discipline to `gh`.
#
# On Windows (WSL-bash / Git Bash) PATH can place a non-executable `gh` ahead of
# the real GitHub CLI — for example a Python-provided `gh` script carrying a
# Windows shebang, which fails with "cannot execute: required file not found."
# A bare `gh` selected by name alone then resolves to that shim and every DevFlow
# helper that shells out to `gh` breaks, even though a working `gh.exe` is present
# later on PATH. Selecting `gh` by name (`command -v gh`) is a presence check; it
# does not confirm the binary actually runs. This helper centralizes the
# "which gh do we use?" decision so preflight (which only DETECTS) and every
# helper (which USES) can never disagree on the contract.
#
# Defines a function only; it deliberately does NOT set -e/-u so it is safe to
# source into a caller with its own shell options (preflight runs `set -u`, the
# helpers run `set -euo pipefail` / `set -uo pipefail`, and
# scripts/authorize-actor.sh — sourced itself — sets no options at all).

# devflow_resolve_gh — echo the `gh` invocation DevFlow should use.
#
#   * An explicit, non-empty DEVFLOW_GH wins outright and is echoed WITHOUT any
#     probe — this preserves the test-suite's stubbing contract (every stubbed
#     helper run sets DEVFLOW_GH to a fake `gh`, which must never be version-
#     checked) and gives a Windows/WSL user a documented escape hatch.
#   * Otherwise the first of `gh`, `gh.exe` that both resolves (`command -v`) AND
#     actually executes (`gh --version`) is echoed — so a present-but-unrunnable
#     `gh` shim is rejected in favor of a runnable `gh.exe`. The probe is
#     `gh --version` only: no network, no authentication, so it cannot hang or
#     fail on an unauthenticated host.
#   * If neither candidate runs, bare `gh` is echoed (with a one-line stderr
#     breadcrumb naming the probe failure and the DEVFLOW_GH remedy) so the
#     caller's existing best-effort warning path still fires (echoed value
#     identical to the old bare-`gh` helper default in that degenerate case).
#
# On Linux/macOS/cloud, where a bare `gh` runs, the first probe succeeds and the
# function returns `gh` — no behavior change and no extra network/auth. Candidate
# binaries are referenced by name only; no absolute or owner-specific install
# path is ever hardcoded. Always returns rc 0 (the caller wants the string).
devflow_resolve_gh() {
  # Explicit override wins with no probe (stub contract + Windows escape hatch).
  if [ -n "${DEVFLOW_GH:-}" ]; then
    printf '%s\n' "$DEVFLOW_GH"
    return 0
  fi
  local cand
  for cand in gh gh.exe; do
    command -v "$cand" >/dev/null 2>&1 || continue
    # Confirm the candidate actually EXECUTES — a present-but-unrunnable shim
    # (bad shebang, cleared exec bit) must not be trusted by name. `--version`
    # is deliberately network- and auth-free.
    "$cand" --version >/dev/null 2>&1 || continue
    printf '%s\n' "$cand"
    return 0
  done
  # No runnable candidate: fall back to bare `gh` so the caller's best-effort
  # warning path still fires (unchanged degenerate behavior). Leave a stderr
  # breadcrumb so the downstream "cannot execute" failure is self-explanatory
  # (stderr only — command substitution captures stdout, so the echoed value
  # stays clean).
  printf 'devflow: no runnable gh or gh.exe found on PATH; falling back to bare "gh" — set DEVFLOW_GH to a working GitHub CLI\n' >&2
  printf 'gh\n'
  return 0
}
