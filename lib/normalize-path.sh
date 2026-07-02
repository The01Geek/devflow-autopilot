#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# normalize-path.sh — convert a Windows-form path (`C:\...` or `C:/...`) into
# the POSIX form the CURRENTLY RUNNING shell expects: WSL bash wants
# /mnt/c/..., Git Bash / MSYS2 wants /c/... (issue #247). Runner-provided
# paths (for example the skill-dir anchor a non-Claude-Code runner reports)
# can arrive in Windows form; handing such a path to a POSIX shell fails.
#
# Non-Windows-form input passes through unchanged and consults no tool — zero
# behavior change on Linux/macOS/cloud.
#
# NOTE (bootstrap constraint): the create-issue skill-dir anchor cannot source
# this helper — the anchor is what LOCATES lib/ in the first place — so
# skills/create-issue/SKILL.md carries an inline mirror of this chain. Keep
# the two in lockstep when changing the translation logic.
#
# Defines a function only; it deliberately does NOT set -e/-u so it is safe to
# source into a caller with its own shell options.

# devflow_normalize_path <path> — echo the POSIX-form equivalent of <path>.
#
# Resolution order (tool-first, because only the tool knows the mount scheme
# with certainty; the env-detected translation is the documented best-effort
# residual):
#   1. `wslpath -u`  (WSL — preferred when present)
#   2. `cygpath -u`  (Git Bash / MSYS2)
#   3. env-detected manual translation:
#        `uname -r` contains "microsoft"  → WSL-style  /mnt/c/...
#        MSYSTEM set (non-empty)          → MSYS-style /c/...
#   4. no tool and no env signal → echo the input unchanged, with a one-line
#      stderr breadcrumb (stderr only — command substitution captures stdout,
#      so the echoed value stays clean).
# Always returns rc 0 (best-effort — the caller always gets a usable string).
devflow_normalize_path() {
  local input="$1" drive rest
  # Inline regex literal, kept form-identical to the SKILL.md mirror so the
  # coupled sites diff cleanly.
  if [[ ! "$input" =~ ^[A-Za-z]:[\\/] ]]; then
    printf '%s\n' "$input"
    return 0
  fi
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -u "$input" 2>/dev/null && return 0
  fi
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$input" 2>/dev/null && return 0
  fi
  drive="$(printf '%s' "${input%%:*}" | tr '[:upper:]' '[:lower:]')"
  rest="${input#?:}"
  rest="${rest//\\//}"
  if uname -r 2>/dev/null | grep -qi microsoft; then
    printf '/mnt/%s%s\n' "$drive" "$rest"
    return 0
  fi
  if [ -n "${MSYSTEM:-}" ]; then
    printf '/%s%s\n' "$drive" "$rest"
    return 0
  fi
  printf 'devflow: could not normalize Windows-form path "%s" (no wslpath/cygpath and no WSL/MSYS environment signal) — using it unchanged\n' "$input" >&2
  printf '%s\n' "$input"
  return 0
}
