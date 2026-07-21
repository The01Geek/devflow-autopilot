#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# ============================================================================
# vendor-slice.sh — materialize the DevFlow plugin into the workspace
# ============================================================================
# The cloud-tier workflows reference plugin helpers at the literal workspace
# path `.devflow/vendor/devflow/…`. This script puts the plugin there at RUNTIME
# so the tree no longer has to be committed into a consumer repo. It is the ONE
# definition of "which files are the plugin" — install.sh sources it for the
# shared `devflow_copy_slice` function (see DEVFLOW_VENDOR_SOURCE below), and the
# vendor-plugin composite action executes it — so the copied set can never drift.
#
# Executed (the composite action), it follows a single deterministic algorithm.
# Only the committed branch is a no-op; the self and fetch branches both copy:
#   1. committed  — `.devflow/vendor/devflow/scripts` already in the checkout → use it (no-op).
#   2. self       — the plugin lives at the checkout root (this source repo)    → copy it in.
#   3. fetch      — neither                                                      → clone DEVFLOW_REF and copy it in.
# The fetch branch refuses to run without a pinned ref, so a thin consumer never
# silently tracks mutable `main`.
#
# Environment (all optional unless noted):
#   DEVFLOW_REF        git ref to fetch (REQUIRED on the fetch branch); a branch,
#                      tag, or commit SHA. Sourced from .devflow/config.json
#                      `devflow_version` by the workflows.
#   DEVFLOW_REPO       owner/name to fetch from (default The01Geek/devflow-autopilot).
#   DEVFLOW_REPO_URL   full clone URL (default https://github.com/$DEVFLOW_REPO.git);
#                      overridable so tests can clone a local fixture offline.
#   DEVFLOW_DEST       destination dir (default .devflow/vendor/devflow); overridable for tests.
#   DEVFLOW_VENDOR_SOURCE=1  define functions and return WITHOUT running — for `source`rs.
# ============================================================================
set -euo pipefail

devflow_vendor_log() { printf 'devflow-vendor: %s\n' "$1"; }
devflow_vendor_die() { printf 'devflow-vendor: %s\n' "$1" >&2; exit 1; }

# Report which branch materialized the plugin: committed | self | fetch.
# Security consumers key TRUST on this — the deny-list floor in
# devflow-runner.yml executes the vendored filter helper ONLY on `fetch` (a
# fresh clone of the official repo at the pinned ref, made this run);
# `committed`/`self` copies come from the checked-out — possibly PR-head — tree
# and are never trusted as floor code (the PR-#404 REJECT finding). Written to
# $GITHUB_OUTPUT when running under the composite action; log-only otherwise
# (install.sh / tests source this file without GITHUB_OUTPUT).
devflow_vendor_report_source() {
  devflow_vendor_log "vendor source: $1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "vendor_source=$1" >> "$GITHUB_OUTPUT"
  fi
}

# The single shared "what is the plugin" definition. Mirrors the file set
# install.sh has always vendored. SRC = a checkout/clone root; DEST = where the
# plugin lands. Stages into a sibling temp dir and swaps in with one atomic `mv`
# at the very end: $dest is only ever touched once the full slice copied cleanly,
# so a partial copy (a removed/renamed slice dir aborting cp under set -e, disk
# full) never lands at $dest — where the committed-branch check would otherwise
# mask it as a valid plugin on the next run.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -R "$src/.claude-plugin" "$src/agents" "$src/docs" "$src/lib" "$src/scripts" "$src/skills" "$stage/"
  # Only the committed templates/registry — not the whole .devflow/ tree (which
  # would drag in learnings/ and a possibly-dirty config.json).
  mkdir -p "$stage/.devflow"
  cp "$src/.devflow/config.example.json" "$src/.devflow/config.schema.json" \
     "$src/.devflow/tool-presets.json" \
     "$stage/.devflow/"
  # The vendored copy is a plugin, not a marketplace — keep only plugin.json.
  rm -f "$stage/.claude-plugin/marketplace.json"
  find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
  # No consumer run reaches the published-site HTML (docs/site/) or DevFlow's own
  # test suite (lib/test/): both land under .devflow/vendor/devflow/, where a
  # repo-root-relative lib/test/run.sh does not resolve and the site artifacts are
  # a web page, not a code path — so ~11M of dead payload ships to every consumer.
  # Prune them from the staged tree here, before the sanity floor (like the
  # marketplace.json/__pycache__ prunes above), so the floor evaluates the tree
  # that actually ships. Scoped to docs/site — the rest of docs/ is linked from
  # shipped skill bodies and must stay (issue #677).
  rm -rf "$stage/docs/site" "$stage/lib/test"
  # Sanity floor before the swap: the load-bearing members must have landed.
  if [ ! -d "$stage/scripts" ] || [ ! -f "$stage/.claude-plugin/plugin.json" ] \
     || [ ! -f "$stage/.devflow/config.schema.json" ]; then
    rm -rf "$stage"
    devflow_vendor_die "incomplete plugin slice copied from $src (missing scripts/, plugin.json, or .devflow templates) — refusing to install a partial copy."
  fi
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$stage" "$dest"
}

devflow_vendor_main() {
  local dest="${DEVFLOW_DEST:-.devflow/vendor/devflow}"

  # 1. committed branch — a consumer that committed the plugin (self-hosting).
  if [ -d "$dest/scripts" ]; then
    devflow_vendor_log "plugin already present at $dest — using the committed copy."
    devflow_vendor_report_source committed
    return 0
  fi

  # 2. self branch — the plugin is in the checkout root (this source repo). The
  #    plugin.json name check is the strong discriminator: a consumer repo with
  #    its own top-level scripts/ (common) won't carry a devflow plugin.json, so
  #    it correctly falls through to fetch.
  if [ -d scripts ] && [ -d skills ] && [ -f .claude-plugin/plugin.json ] \
     && grep -Eq '"name"[[:space:]]*:[[:space:]]*"devflow"' .claude-plugin/plugin.json; then
    devflow_vendor_log "self: copying plugin from the checkout root → $dest"
    devflow_copy_slice "." "$dest"
    devflow_vendor_report_source self
    return 0
  fi

  # 3. fetch branch — a thin consumer; clone the pinned ref and copy it in.
  [ -n "${DEVFLOW_REF:-}" ] || devflow_vendor_die \
    "no plugin in the checkout and DEVFLOW_REF (config devflow_version) is unset — refusing to track mutable main. Set .devflow/config.json devflow_version to a tag, branch, or commit SHA."
  local repo url tmp
  repo="${DEVFLOW_REPO:-The01Geek/devflow-autopilot}"
  url="${DEVFLOW_REPO_URL:-https://github.com/${repo}.git}"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  devflow_vendor_log "fetch: cloning $url @ $DEVFLOW_REF"
  # Fast path: shallow clone of a branch/tag. Fallback: full clone + checkout,
  # which also resolves a commit SHA (which --branch cannot take). Mirrors the
  # clone fallback install.sh uses. stderr is suppressed ONLY on the --branch
  # attempt — a SHA legitimately fails it, and that expected failure must stay
  # quiet. The fallback clone and checkout each capture their stderr so a
  # genuine fetch failure reports its real cause (auth, network, not-found,
  # rate-limit) instead of a generic message, and a failed checkout after a
  # successful clone is distinguishable from a total clone failure.
  local clone_err checkout_err
  if ! git clone --quiet --depth 1 --branch "$DEVFLOW_REF" "$url" "$tmp/src" 2>/dev/null; then
    rm -rf "$tmp/src"
    if ! clone_err="$(git clone --quiet "$url" "$tmp/src" 2>&1)"; then
      devflow_vendor_die "could not fetch $url @ $DEVFLOW_REF — clone failed: $clone_err"
    fi
    if ! checkout_err="$(git -C "$tmp/src" checkout --quiet "$DEVFLOW_REF" 2>&1)"; then
      devflow_vendor_die "could not fetch $url @ $DEVFLOW_REF — clone succeeded but checkout failed: $checkout_err"
    fi
  fi
  devflow_copy_slice "$tmp/src" "$dest"
  devflow_vendor_report_source fetch
}

# Sourced (install.sh, tests) → expose the functions and stop. Executed (the
# composite action) → run the algorithm.
if [ "${DEVFLOW_VENDOR_SOURCE:-}" = "1" ]; then return 0 2>/dev/null || true; fi
devflow_vendor_main "$@"
