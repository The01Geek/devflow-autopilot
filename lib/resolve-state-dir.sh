#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-state-dir.sh — PRFlow's state-directory resolution contract, sourced by
# every SHELL reader that resolves the repo-root-anchored state directory
# (scripts/config-get.sh, scripts/load-prompt-extension.sh,
# scripts/detect-project-tools.sh, lib/config-source.sh). Its Python sibling is
# lib/state_dir.py; the two are a COUPLED PAIR and are edited together, because a
# `.sh` cannot be exec'd from the Python readers on Windows ([WinError 193], the
# issue-#275 rule) and a `.py` cannot be sourced into a shell.
#
# THE TRANSITIONAL READ-THROUGH (issue #1002). The canonical directory is
# `.prflow/`. A reader falls back to the superseded `.devflow/` ONLY when the
# canonical path is absent AND the superseded one is present, and every such
# resolution writes a stderr breadcrumb naming `/prflow:init`.
#
# Why a fallback exists here when issue #988 ruled one out for the config KEYS:
# they are different failure surfaces. `/prflow:init` registers the marketplace
# with `autoUpdate: true`, so a consumer's PLUGIN can update ahead of any
# migration run. Without the fallback the next auto-update resolves an absent
# config and every `// default` extraction silently reverts — the exact silent
# revert the migration exists to prevent, reached before any breadcrumb or gate
# could run. A LOUD fallback keeps the tree working while staying observable, so
# it is not the unobservable-and-therefore-permanent fallback #988 rejected. The
# key-level rule is unchanged: no read-through for `devflow_* -> prflow_*`.
#
# The end criterion for this window is recorded in lib/rename-map.json
# (`transitional_read_through.end_criterion`) — it is confirmation-gated, not a
# timer. lib/test/run.sh pins the literals below against that table.
#
# Defines/assigns only; deliberately no set -e/-u — safe to source into a caller
# with its own shell options.

# The two directory names. Coupled with lib/rename-map.json's
# `paths.state_dir` and with lib/state_dir.py; a suite assertion fails when the
# three disagree.
PRFLOW_STATE_DIR_CURRENT='.prflow'
PRFLOW_STATE_DIR_SUPERSEDED='.devflow'

# prflow_state_dir <repo_root>
#   Prints the resolved state-directory path for $1 on stdout, always exit 0.
#   Callers compose their own file path under it, so the answer is a directory,
#   never a file. `[ -d ]` is the test on purpose: a plain FILE or a dangling
#   symlink at either name is not a state directory, and treating one as present
#   would route a reader into a path it cannot read from.
prflow_state_dir() {
  local root="${1:-}"
  if [ -d "${root}/${PRFLOW_STATE_DIR_CURRENT}" ]; then
    printf '%s' "${root}/${PRFLOW_STATE_DIR_CURRENT}"
    return 0
  fi
  if [ -d "${root}/${PRFLOW_STATE_DIR_SUPERSEDED}" ]; then
    prflow_state_dir_breadcrumb "$root"
    printf '%s' "${root}/${PRFLOW_STATE_DIR_SUPERSEDED}"
    return 0
  fi
  # Neither present: hand back the CANONICAL path. There is nothing to migrate,
  # so this is a fresh repo rather than a stale one and it earns no breadcrumb —
  # emitting one here would train operators to ignore the line that matters.
  printf '%s' "${root}/${PRFLOW_STATE_DIR_CURRENT}"
}

# The breadcrumb, factored out so the wording exists once and the suite can drive
# it directly. Written to stderr so it never contaminates a caller's captured
# stdout value.
prflow_state_dir_breadcrumb() {
  printf 'prflow: reading the superseded %s/ state directory in %s — run /prflow:init to migrate it to %s/ (this transitional fallback is removed once no consumer still carries %s/; see lib/rename-map.json)\n' \
    "$PRFLOW_STATE_DIR_SUPERSEDED" "${1:-.}" "$PRFLOW_STATE_DIR_CURRENT" "$PRFLOW_STATE_DIR_SUPERSEDED" >&2
}
