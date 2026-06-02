#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Print a consumer-owned prompt-extension file verbatim, if present.
#
# Usage: load-prompt-extension.sh SKILL_NAME
#   SKILL_NAME   the skill's directory name under skills/ (e.g. create-issue,
#                implement, review). This is the ONLY argument.
#
# Reads .devflow/prompt-extensions/<SKILL_NAME>.md relative to the current
# working directory (the consumer repo root) and writes it byte-for-byte to
# stdout when it exists. When the file is absent — or present but empty — this
# prints nothing and exits 0 (the no-op path), so a skill that calls this
# behaves exactly as before unless the consumer opted in.
#
# This is DevFlow's single upgrade-safe extension point: a consumer adds
# repo-specific instructions to any skill by committing one Markdown file in
# their own repo, with no plugin edit and no fork to maintain. The file lives in
# the consumer's repo, never in the plugin, so marketplace updates never touch
# it and never conflict with it. The skill that calls this treats the printed
# text as additional instructions appended to the end of its own prompt.
#
# SKILL_NAME is validated BEFORE any filesystem access: a value that is empty or
# contains a '/' character or a '..' sequence is rejected (exit 2). This
# constrains the *name* — so the model-executed argument can never name a file
# outside .devflow/prompt-extensions/ — NOT the resolved target: a symlink the
# repo owner commits inside that directory is still followed by `cat`. That is by
# design — the directory's contents are consumer-owned trusted prose, and a
# consumer who symlinks outward is only reaching into their own repo. The argument
# is the only attacker-influenceable input (a skill could be coaxed to pass an
# unexpected value); the file's bytes are trusted.
#
# Plain POSIX-portable shell, no GNU-only flags — runs on macOS/BSD without GNU
# coreutils. `cat` reproduces the file's bytes exactly, adding or stripping no
# trailing newline beyond the file's own.
#
# Exit codes:
#   0  file printed verbatim, or absent/empty (no-op)
#   2  bad arguments (missing SKILL_NAME, or it contains '/' or '..'), OR the named
#      extension exists but cannot be delivered as a Markdown file (unreadable, a
#      symlink whose target is missing, or not a regular file — a directory or a
#      symlink resolving to one) — refused loudly rather than left to masquerade as
#      the empty no-op the calling skill treats as "proceed unchanged", which would
#      silently drop the consumer's customization

set -euo pipefail

skill="${1:-}"

if [ -z "$skill" ]; then
    echo "load-prompt-extension.sh: usage: load-prompt-extension.sh SKILL_NAME" >&2
    exit 2
fi

# Reject path-traversal vectors before touching the filesystem. '*/*' matches any
# slash; '*..*' matches any '..' sequence (covering '..', '../x', 'x/../y').
case "$skill" in
    */* | *..*)
        echo "load-prompt-extension.sh: invalid skill name '$skill' (must not contain '/' or '..')" >&2
        exit 2
        ;;
esac

ext_file=".devflow/prompt-extensions/${skill}.md"

# Refuse every "present but undeliverable" shape loudly (exit 2 + a specific
# breadcrumb) instead of letting it fall through to the silent empty no-op the
# calling skill reads as "proceed unchanged" — that would drop the consumer
# extension. The guards below partition those shapes; an absent file (none of them
# fire) is the only path that reaches the no-op exit 0 at the very end.
#
# A symlink whose target is missing makes the `-f` test below false, so without
# this branch a committed `<skill>.md -> ../moved.md` (or a link that resolves only
# on another machine) would silently no-op and drop the consumer extension — the
# same failure class the unreadable guard below closes. Refuse it loudly too.
# (-L true AND -e false = a present-but-broken symlink; a resolvable symlink is
# -e true and is followed by design, per the header.)
if [ -L "$ext_file" ] && [ ! -e "$ext_file" ]; then
    echo "load-prompt-extension.sh: '$ext_file' is a symlink with a missing target; refusing to silently skip a consumer extension (fix or remove the link)" >&2
    exit 2
fi

# A present entry that is NOT a regular file — a directory (e.g. a fat-fingered
# `mkdir <skill>.md`), a symlink resolving to a directory, a fifo/device — also
# makes the `-f` test below false and would silently no-op, dropping the consumer
# extension (same class as the guards above). Refuse it loudly. A regular file, or
# a symlink resolving to one, is `-f` true and falls through to be read.
if [ -e "$ext_file" ] && [ ! -f "$ext_file" ]; then
    echo "load-prompt-extension.sh: '$ext_file' exists but is not a regular file; refusing to silently skip a consumer extension (expected a Markdown file)" >&2
    exit 2
fi

# By here the broken-symlink and non-regular guards above have fired on every
# undeliverable *present* shape, so the only present case reaching `-f` is a
# regular file (an absent file makes `-f` false → the no-op exit 0 at the end).
# A present-but-unreadable regular file is still refused loudly (exit 2) rather
# than letting a bare `cat` failure under `set -e` masquerade as the empty no-op
# the calling skill reads as "proceed unchanged". (Note: a process running as root
# bypasses the permission bits, so this guard only fires for an ordinary user.)
if [ -f "$ext_file" ]; then
    if [ ! -r "$ext_file" ]; then
        echo "load-prompt-extension.sh: '$ext_file' exists but is not readable; refusing to silently skip a consumer extension (fix its permissions)" >&2
        exit 2
    fi
    cat "$ext_file"
fi
