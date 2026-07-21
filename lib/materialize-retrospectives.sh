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

# Redact operator home-directory paths before merge (issue #672), in ONE
# streaming jq pass over the new-entries file. This is the single deterministic
# choke point: it fires on every merged record regardless of which of the three
# producers (clean-entry.jq, the Stage A subagent, the inline skip marker)
# emitted it, so no per-producer instruction is relied on. Every string VALUE is
# rewritten via walk (keys and non-string types are left untouched, so .pr/.kind
# — numeric/enum — survive and the merge key still resolves). CLAUDE.md
# guard-class 2: this transform decides an emitted result, so it is expressed
# through the resolved $DEVFLOW_JQ, never a non-preflight PATH tool (sed/tr/cut/wc)
# that would fail open by writing the unredacted line. The /home/runner(admin)?
# carve-out preserves GitHub-Actions runner paths, which identify no person and
# carry the friction the record exists to describe. A per-file pass (rather than
# a jq fork per record inside the loop) is equivalent because redaction is
# per-record-independent and touches only values; a malformed new-entries file
# falls back to the raw copy so the existing post-merge JSONL validation still
# reports it (and a file that fails to parse never writes a committed corpus, so
# skipping redaction on that path leaks nothing).
REDACTED="$(mktemp)"
trap 'rm -f "$TMP" "$REDACTED"' EXIT
if ! "$DEVFLOW_JQ" -c '
        def redact_home:
          gsub("(?<d>^|[^A-Za-z0-9_])/Users/(?!runner(admin)?/)[^/\\s\"]+/"; "\(.d)~/")
          | gsub("(?<d>^|[^A-Za-z0-9_])/home/(?!runner(admin)?/)[^/\\s\"]+/"; "\(.d)~/")
          | gsub("[A-Za-z]:\\\\Users\\\\[^\\\\\\s\"]+\\\\"; "~\\");
        walk(if type == "string" then redact_home else . end)' "$NEW_FILE" > "$REDACTED" 2>/dev/null; then
    cp "$NEW_FILE" "$REDACTED"
fi

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
        trap "rm -f '$NEW_TMP' '$TMP' '$REDACTED'" EXIT
        "$DEVFLOW_JQ" -c --argjson pr "$pr" --arg kind "$kind" --argjson repl "$line" \
            'if .pr==$pr and .kind==$kind then $repl else . end' "$TMP" > "$NEW_TMP"
        mv "$NEW_TMP" "$TMP"
        # Restore trap to only clean $TMP/$REDACTED now that $NEW_TMP is gone (renamed to $TMP)
        trap 'rm -f "$TMP" "$REDACTED"' EXIT
        REP=$((REP + 1))
    else
        printf '%s\n' "$line" >> "$TMP"
        APP=$((APP + 1))
    fi
done < "$REDACTED"

# Validate the merged result
if ! "$DEVFLOW_JQ" -c . "$TMP" > /dev/null 2>&1; then
    echo "materialize: invalid JSONL after merge" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$JSONL_PATH"
echo "materialized: appended $APP, replaced $REP"
