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
# contains a '/' character or a '..' sequence is rejected (exit 2), so the
# resolved path can never escape .devflow/prompt-extensions/. (The file's own
# contents are consumer-owned trusted prose by design; only the model-supplied
# name is constrained here.)
#
# Plain POSIX-portable shell, no GNU-only flags — runs on macOS/BSD without GNU
# coreutils. `cat` reproduces the file's bytes exactly, adding or stripping no
# trailing newline beyond the file's own.
#
# Exit codes:
#   0  file printed verbatim, or absent/empty (no-op)
#   2  bad arguments (missing SKILL_NAME, or it contains '/' or '..')

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

# Absent → no-op (nothing printed, exit 0). Present → emit verbatim. An empty
# file naturally prints nothing. -f also rules out a directory at that path.
if [ -f "$ext_file" ]; then
    cat "$ext_file"
fi
