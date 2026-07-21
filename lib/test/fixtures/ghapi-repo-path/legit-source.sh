#!/usr/bin/env bash
# Legitimate corpus. Every shape below must be left unflagged.
# This comment line names $GITHUB_REPOSITORY and must not be read as a command.
set -euo pipefail

# A --repo flag value is not a REST path argument.
scripts/react-to-trigger.sh --repo "$GITHUB_REPOSITORY" --reaction hooray

# A run-URL composition is not a REST path argument.
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
echo "$RUN_URL"

# The placeholder form is the correct idiom and is never flagged.
gh api "repos/{owner}/{repo}/issues/1/comments?per_page=100"

# A gh call that is not the `api` subcommand.
gh pr view 1 --json number

# `api` reached through a non-gh head.
curl api "repos/$GITHUB_REPOSITORY/issues/1"
