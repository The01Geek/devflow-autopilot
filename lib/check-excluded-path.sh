#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# check-excluded-path.sh — check repo-relative paths against the exclusion list.
#
# Usage:
#   bash check-excluded-path.sh path1 path2 ...   # positional args
#   echo "path" | bash check-excluded-path.sh      # stdin (one path per line)
#
# Exits 0 and prints excluded paths (one per line) if ANY match the exclusion list.
# Exits 1 and prints nothing if NONE are excluded.

set -euo pipefail

# Collect input paths: args take priority over stdin
if [ "$#" -gt 0 ]; then
    paths=("$@")
else
    paths=()
    while IFS= read -r line; do
        paths+=("$line")
    done
fi

excluded=()

for p in "${paths[@]}"; do
    case "$p" in
        # DevFlow's own engine files. Post-extraction the plugin IS this repo,
        # so the engine lives at the root (skills/, agents/, lib/, scripts/,
        # .claude-plugin/). NOTE: these globs are tuned for the devflow-autopilot
        # repo. An adopter who runs the retrospective loop on a repo that also
        # has top-level skills/, lib/, or scripts/ directories may want to
        # narrow this list (it only affects which of their PRs the loop skips).
        skills/*|agents/*|lib/*|scripts/*|.claude-plugin/*)
            excluded+=("$p") ;;
        .devflow/learnings/*)
            excluded+=("$p") ;;
        .github/actions/*)
            excluded+=("$p") ;;
        .github/workflows/claude*.yml|.github/workflows/devflow-*.yml)
            excluded+=("$p") ;;
        .github/project-config.yml|.github/project-config.example.yml)
            excluded+=("$p") ;;
    esac
done

if [ "${#excluded[@]}" -gt 0 ]; then
    printf '%s\n' "${excluded[@]}"
    exit 0
fi

exit 1
