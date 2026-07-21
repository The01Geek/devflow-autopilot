#!/usr/bin/env bash
echo one
echo two
gh api "repos/$GITHUB_REPOSITORY/issues/1"
