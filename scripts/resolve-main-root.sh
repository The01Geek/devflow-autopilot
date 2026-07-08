#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-main-root.sh — print the absolute path of the MAIN working-tree root.
#
# Prints the main repo root when run from inside a linked git worktree (e.g. a
# Claude worktree under `.claude/worktrees/<name>/`), the repo root when run from
# a normal single-tree checkout, and falls back to `pwd` (with a specific stderr
# breadcrumb) when git is unavailable, the cwd is not a git repo, or the main
# repo is bare. Like `scripts/ensure-label.sh` / `scripts/apply-labels.sh`, this
# is a best-effort helper: it ALWAYS exits 0, so a resolution hiccup can never
# abort the caller — but it leaves a specific stderr breadcrumb on the fallback
# path so a real failure is visible rather than silently swallowed.
#
# This is a DISTINCT resolution from the `.devflow/` repo-root anchoring used by
# config-get.sh / config-source.sh / workpad.py (issue #295), which resolve the
# *nearest* git root via `git rev-parse --show-toplevel` — that returns the
# WORKTREE when inside one, which is deliberately NOT what this helper wants. The
# main worktree is always the first record of `git worktree list --porcelain`
# (portable to git >= 2.7). `git` is invoked directly here, matching
# `lib/config-source.sh` (git is not part of the `resolve-*.sh` binary-resolver
# family).
set -uo pipefail

# `git worktree list --porcelain` groups records (one per worktree) separated by
# blank lines; the FIRST record is always the main worktree, whose `worktree`
# attribute line carries its absolute path. Empty output means git failed / the
# cwd is not a repo — main_root ends up empty and we fall back to pwd below.
porcelain="$(git worktree list --porcelain 2>/dev/null)"
main_root="$(printf '%s\n' "$porcelain" | head -n 1 | sed 's/^worktree //')"

# A BARE main repo lists its first record with a `bare` attribute and a worktree
# path pointing at the bare git dir, which is not a usable working tree — treat
# it as unresolved and fall back to pwd (the degenerate case). Inspect only the
# first record (lines 1..first blank line).
if printf '%s\n' "$porcelain" | sed -n '1,/^$/p' | grep -qx 'bare'; then
    main_root=""
fi

if [ -n "$main_root" ] && [ -d "$main_root" ]; then
    printf '%s\n' "$main_root"
else
    echo "devflow: resolve-main-root: could not determine the main working-tree root (git unavailable, not a git repo, or a bare main repo) — falling back to '$(pwd)'" >&2
    pwd
fi

exit 0
