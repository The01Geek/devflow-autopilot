#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-gh.sh — DevFlow's GitHub-CLI (`gh`) selection contract, sourced by
# lib/preflight.sh and every gh-calling shell helper. Since issue #247 the
# generic detect-and-verify mechanics live in lib/resolve-bin.sh (the shared
# execution-verified resolver, extracted from this file); devflow_resolve_gh is
# a thin delegation kept as its own file because every gh-calling helper and
# ~15 tests source resolve-gh.sh by name.
#
# The contract is unchanged from #245: an explicit, non-empty DEVFLOW_GH wins
# outright WITHOUT any probe (DEVFLOW_GH is exactly the override name
# devflow_resolve_bin derives for "gh", so the test suite's stubbing contract
# is preserved); otherwise the first of the candidates gh, gh.exe that both
# resolves (`command -v`) AND actually executes (`gh --version` — network- and
# auth-free) is echoed, rejecting a present-but-unrunnable shim; if neither
# runs, bare `gh` is echoed with a stderr breadcrumb naming the DEVFLOW_GH
# remedy. Candidates are referenced by name only — no absolute or
# owner-specific install path is ever hardcoded. Always returns rc 0.
#
# Defines a function only; it deliberately does NOT set -e/-u so it is safe to
# source into a caller with its own shell options (preflight runs `set -u`, the
# helpers run `set -euo pipefail` / `set -uo pipefail`, and
# scripts/authorize-actor.sh — sourced itself — sets no options at all).

# Pure-bash directory derivation (no `dirname`): this file must stay sourceable
# in a degenerate environment with an empty PATH (the resolver family's own
# degenerate-path tests run with only bash present).
case "${BASH_SOURCE[0]}" in
  */*) _RESOLVE_GH_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
  *)   _RESOLVE_GH_DIR="$(pwd)" ;;
esac
# shellcheck source=resolve-bin.sh
. "$_RESOLVE_GH_DIR/resolve-bin.sh"

# devflow_resolve_gh — echo the `gh` invocation DevFlow should use. See
# lib/resolve-bin.sh for the full override/probe/fallback contract.
devflow_resolve_gh() {
  devflow_resolve_bin gh
}
