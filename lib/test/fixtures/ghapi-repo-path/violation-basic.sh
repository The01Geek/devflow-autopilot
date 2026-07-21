#!/usr/bin/env bash
# Two planted violations in one file; each must be reported on its own line.
gh api "repos/$GITHUB_REPOSITORY/issues/1"
echo separator
ID=$(gh api "repos/$GITHUB_REPOSITORY/issues/2/comments" --jq '.[0].id')
echo "$ID"
