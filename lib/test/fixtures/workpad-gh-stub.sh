#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# workpad-gh-stub.sh — fake `gh` for workpad.sh tests.
# Covers the API endpoints used by workpad.sh subcommands.
# Set WORKPAD_PATCH_SINK to a file path to capture PATCH bodies.

FX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The workpad comment body (shared across stubs)
WORKPAD_BODY='<!-- devflow:workpad -->
# DevFlow Workpad — Issue #99

**Status:** Implementing
**Branch:** `feat/test`
**Last updated:** 2026-05-15T00:00:00Z

## Plan
- [ ] Step alpha
- [ ] Step beta
- [ ] Step gamma

## Acceptance Criteria
- [ ] AC one
- [ ] AC two

## Decisions / Notes

## Devflow Reflection
'

ARGS="$*"

# gh repo view --json nameWithOwner -q .nameWithOwner
if printf '%s' "${ARGS}" | grep -q "repo view"; then
    printf 'acme/example-repo\n'
    exit 0
fi

# gh issue comment ISSUE --body-file FILE  (cmd_create)
if printf '%s' "${ARGS}" | grep -q "issue comment"; then
    printf 'https://github.com/acme/example-repo/issues/99#issuecomment-9001\n'
    exit 0
fi

# gh api -X PATCH .../issues/comments/9001 ... (cmd_patch / cmd_update)
if printf '%s' "${ARGS}" | grep -qE "\-X[[:space:]]+PATCH"; then
    # Find -F body=@FILE argument and read the file.
    local_file=""
    prev=""
    for arg in $ARGS; do
        if [ "${prev}" = "-F" ]; then
            # arg is body=@FILE
            local_file="${arg#body=@}"
            break
        fi
        prev="${arg}"
    done
    if [ -n "${local_file}" ] && [ -f "${local_file}" ]; then
        cat "${local_file}"
    else
        printf '%s' "${WORKPAD_BODY}"
    fi
    exit 0
fi

# gh api /repos/.../issues/99/comments?page=N&per_page=100  (list comments)
if printf '%s' "${ARGS}" | grep -qE "issues/[0-9]+/comments"; then
    printf '%s' "${WORKPAD_BODY}" | jq -Rs '[{"id":9001,"body":.}]'
    exit 0
fi

# gh api /repos/.../issues/comments/9001  (single comment body fetch)
if printf '%s' "${ARGS}" | grep -qE "issues/comments/[0-9]+"; then
    printf '%s' "${WORKPAD_BODY}" | jq -Rs '{"id":9001,"body":.}'
    exit 0
fi

# Fallback
printf '[]\n'
exit 0
