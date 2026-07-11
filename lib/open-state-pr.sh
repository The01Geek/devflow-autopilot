#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# open-state-pr.sh — commit the learnings files onto a per-run branch and open/update a PR.
#
# Usage:
#   open-state-pr.sh [--branch <name>] [--base <ref>] [--dry-run]
#
# --base defaults to "main": the per-run branch is (re)created from that ref so
# the resulting PR diff contains only the learnings files, never whatever the
# operator happened to have checked out. The untracked .devflow/learnings/*
# files survive the checkout and are committed onto the new branch.
#
# Prints the PR number to stdout (or "DRYRUN" in dry-run mode).
set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
DEFAULT_BRANCH="devflow/learnings-$(date -u +%F)"
BRANCH="$DEFAULT_BRANCH"
BASE="main"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)  BRANCH="$2"; shift 2 ;;
        --base)    BASE="$2";   shift 2 ;;
        --dry-run) DRY_RUN=1;   shift   ;;
        *) echo "open-state-pr: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins (injection for tests) ─────────────────────
# shellcheck source=resolve-gh.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

# ── Determine entry count ─────────────────────────────────────────────────────
N=0
if [ -f .devflow/learnings/retrospectives.jsonl ]; then
    N=$(wc -l < .devflow/learnings/retrospectives.jsonl | tr -d ' ')
fi

# ── Commit metadata ───────────────────────────────────────────────────────────
WEEK_LABEL="$(date -u +%G-W%V)"
SUBJECT="chore(devflow): retrospectives for ${WEEK_LABEL} (${N} entries)"
BODY="Retrospective entries from the $(date -u +%F) /devflow:retrospective-weekly run. Merge once CI passes."

# ── Helper: run or dry-run a command ─────────────────────────────────────────
_run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'DRYRUN: %s\n' "$*"
    else
        "$@"
    fi
}

# ── Step 1: (re)create the per-run branch from $BASE ──────────────────────────
# Basing on $BASE (not the current HEAD) keeps the PR diff to just the learnings
# files even if the operator was on a feature branch when invoking the loop.
if [ "$DRY_RUN" -eq 0 ] && ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "open-state-pr: base ref '$BASE' not found — fetch it or pass --base" >&2
    exit 1
fi
_run git checkout -B "$BRANCH" "$BASE"

# ── Step 2: stage learnings files ─────────────────────────────────────────────
# Stage only files that exist: overrides.json is optional (created by meta-issue.sh);
# experiment-records.jsonl is optional (written by build-experiment-records.py between
# retrospective-weekly Steps 5 and 7 — issue #431 — so the state PR commits it and
# main's tree is clean entering Stage B).
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRYRUN: git add <existing learnings files>\n'
else
    for _f in .devflow/learnings/retrospectives.jsonl .devflow/learnings/overrides.json .devflow/learnings/experiment-records.jsonl; do
        if [ -f "$_f" ]; then
            git add "$_f"
        fi
    done
fi

# ── Step 3: commit (skip if nothing staged) ───────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRYRUN: git commit -m "%s" -m "%s"\n' "$SUBJECT" "$BODY"
else
    if git diff --cached --quiet; then
        echo "open-state-pr: nothing staged, skipping commit" >&2
    else
        git commit -m "$SUBJECT" -m "$BODY"
    fi
fi

# ── Step 4: push ──────────────────────────────────────────────────────────────
PUSH_OPTS="-u origin $BRANCH"
if [ "$DRY_RUN" -eq 0 ]; then
    if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
        git push --force-with-lease -u origin "$BRANCH"
    else
        git push -u origin "$BRANCH"
    fi
else
    # Check whether remote branch exists (best-effort; don't fail in dry-run)
    if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
        printf 'DRYRUN: git push --force-with-lease %s\n' "$PUSH_OPTS"
    else
        printf 'DRYRUN: git push %s\n' "$PUSH_OPTS"
    fi
fi

# ── Step 5: open or update PR ─────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRYRUN: %s pr list / pr create or pr edit\n' "$DEVFLOW_GH"
    echo "DRYRUN"
    exit 0
fi

EXISTING_PR="$("$DEVFLOW_GH" pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"

if [ -n "$EXISTING_PR" ]; then
    "$DEVFLOW_GH" pr edit "$EXISTING_PR" --title "$SUBJECT"
    echo "$EXISTING_PR"
else
    # gh pr create prints the new PR URL to stdout; keep it off our stdout
    # (callers capture stdout to read the PR number) but surface it for logs.
    "$DEVFLOW_GH" pr create \
        --base "$BASE" \
        --head "$BRANCH" \
        --title "$SUBJECT" \
        --body "$BODY" >&2
    # Re-list to get the number
    PR_NUMBER="$("$DEVFLOW_GH" pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
    if [ -z "$PR_NUMBER" ]; then
        echo "open-state-pr: pr create succeeded but re-list returned no PR number" >&2
        exit 1
    fi
    echo "$PR_NUMBER"
fi
