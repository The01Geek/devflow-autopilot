#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# materialize-retrospectives.sh <new-entries-file> <jsonl-path>
#
# Merges new JSONL entries into the retrospectives file idempotently.
# For each new entry: if an existing entry has the same .pr AND .kind,
# REPLACE it in place; otherwise APPEND at the end.
# Writes to a temp file and only replaces $2 after validation passes.
#
# Output: "materialized: appended <N>, replaced <M>"

set -euo pipefail

# jq binary: resolved once via the sourced sibling resolver (issue #247);
# best-effort — a copied/vendored deployment without lib/ falls back to bare
# `jq` with a breadcrumb rather than aborting under set -e.
# shellcheck source=resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

if [ "$#" -ne 2 ]; then
    echo "Usage: materialize-retrospectives.sh <new-entries-file> <jsonl-path>" >&2
    exit 1
fi

NEW_FILE="$1"
JSONL_PATH="$2"

# Early exit if new-entries file doesn't exist (every analyzed subagent failed).
if [ ! -f "$NEW_FILE" ]; then
    echo "materialized: appended 0, replaced 0"
    exit 0
fi

# Ensure target file exists
if [ ! -f "$JSONL_PATH" ]; then
    touch "$JSONL_PATH"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
# Populate temp with existing content (empty if file is empty)
cp "$JSONL_PATH" "$TMP"

APP=0
REP=0

while IFS= read -r line; do
    [ -z "$line" ] && continue

    pr="$("$DEVFLOW_JQ" -r '.pr' <<<"$line")"
    kind="$("$DEVFLOW_JQ" -r '.kind' <<<"$line")"

    # Check if an entry with same pr and kind already exists
    # Do NOT suppress jq errors here: a malformed dataset should fail loudly
    # rather than producing a spurious empty $existing and appending a duplicate.
    existing="$("$DEVFLOW_JQ" -c --argjson pr "$pr" --arg kind "$kind" \
        'select(.pr==$pr and .kind==$kind)' "$TMP")"

    if [ -n "$existing" ]; then
        # Replace in place — run per-line through jq substituting the match
        NEW_TMP="$(mktemp)"
        # shellcheck disable=SC2064
        trap "rm -f '$NEW_TMP' '$TMP'" EXIT
        "$DEVFLOW_JQ" -c --argjson pr "$pr" --arg kind "$kind" --argjson repl "$line" \
            'if .pr==$pr and .kind==$kind then $repl else . end' "$TMP" > "$NEW_TMP"
        mv "$NEW_TMP" "$TMP"
        # Restore trap to only clean $TMP now that $NEW_TMP is gone (renamed to $TMP)
        trap 'rm -f "$TMP"' EXIT
        REP=$((REP + 1))
    else
        printf '%s\n' "$line" >> "$TMP"
        APP=$((APP + 1))
    fi
done < "$NEW_FILE"

# Validate the merged result
if ! "$DEVFLOW_JQ" -c . "$TMP" > /dev/null 2>&1; then
    echo "materialize: invalid JSONL after merge" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$JSONL_PATH"
echo "materialized: appended $APP, replaced $REP"
