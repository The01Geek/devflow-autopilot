#!/usr/bin/env bash
# A stray non-UTF-8 byte (ÿ) must not drop this file from the audit.
gh api "repos/$GITHUB_REPOSITORY/issues/1"
