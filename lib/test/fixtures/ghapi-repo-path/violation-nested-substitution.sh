#!/usr/bin/env bash
# A gh api call nested two substitutions deep — the descent must reach it.
RESULT=$(printf '%s' "$(gh api "repos/$GITHUB_REPOSITORY/issues/1" --jq '.id')")
echo "$RESULT"
