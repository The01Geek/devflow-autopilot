#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# ============================================================================
# vendor-slice.sh — materialize the DevFlow plugin into the workspace
# ============================================================================
# The cloud-tier workflows reference plugin helpers at the literal workspace
# path `.claude/plugins/devflow/…`. This script puts the plugin there at RUNTIME
# so the tree no longer has to be committed into a consumer repo. It is the ONE
# definition of "which files are the plugin" — install.sh sources it for the
# shared `devflow_copy_slice` function (see DEVFLOW_VENDOR_SOURCE below), and the
# vendor-plugin composite action executes it — so the copied set can never drift.
#
# Executed (the composite action), it follows a single deterministic algorithm,
# writing nothing when the plugin is already present:
#   1. committed  — `.claude/plugins/devflow/scripts` already in the checkout → use it (no-op).
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
#   DEVFLOW_DEST       destination dir (default .claude/plugins/devflow); overridable for tests.
#   DEVFLOW_VENDOR_SOURCE=1  define functions and return WITHOUT running — for `source`rs.
# ============================================================================
set -euo pipefail

devflow_vendor_log() { printf 'devflow-vendor: %s\n' "$1"; }
devflow_vendor_die() { printf 'devflow-vendor: %s\n' "$1" >&2; exit 1; }

# The single shared "what is the plugin" definition. Mirrors the file set
# install.sh has always vendored. SRC = a checkout/clone root; DEST = where the
# plugin lands. Replaces DEST wholesale so a partial/stale copy can't survive.
devflow_copy_slice() {
  local src="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$src/.claude-plugin" "$src/agents" "$src/lib" "$src/scripts" "$src/skills" "$dest/"
  # Only the committed templates/registry — not the whole .devflow/ tree (which
  # would drag in learnings/ and a possibly-dirty config.json).
  mkdir -p "$dest/.devflow"
  cp "$src/.devflow/config.example.json" "$src/.devflow/config.schema.json" \
     "$src/.devflow/tool-presets.json" \
     "$dest/.devflow/"
  # The vendored copy is a plugin, not a marketplace — keep only plugin.json.
  rm -f "$dest/.claude-plugin/marketplace.json"
  find "$dest" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
}

devflow_vendor_main() {
  local dest="${DEVFLOW_DEST:-.claude/plugins/devflow}"

  # 1. committed branch — a consumer that committed the plugin (self-hosting).
  if [ -d "$dest/scripts" ]; then
    devflow_vendor_log "plugin already present at $dest — using the committed copy."
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
  # clone fallback install.sh uses.
  git clone --quiet --depth 1 --branch "$DEVFLOW_REF" "$url" "$tmp/src" 2>/dev/null \
    || { rm -rf "$tmp/src"; git clone --quiet "$url" "$tmp/src" \
         && git -C "$tmp/src" checkout --quiet "$DEVFLOW_REF"; } \
    || devflow_vendor_die "could not fetch $url @ $DEVFLOW_REF"
  devflow_copy_slice "$tmp/src" "$dest"
}

# Sourced (install.sh, tests) → expose the functions and stop. Executed (the
# composite action) → run the algorithm.
if [ "${DEVFLOW_VENDOR_SOURCE:-}" = "1" ]; then return 0 2>/dev/null || true; fi
devflow_vendor_main "$@"
