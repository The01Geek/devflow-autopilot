#!/usr/bin/env bash
# The real fence wraps its path argument onto the head's line with a backslash
# continuation; the scanner folds it and attributes the violation to the head line.
gh api "repos/$GITHUB_REPOSITORY/issues/1/comments?per_page=100" \
  --jq '.[0].id'
