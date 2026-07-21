#!/usr/bin/env bash
# A flag between the head and the `api` subcommand must not hide the call.
gh -R owner/repo api "repos/$GITHUB_REPOSITORY/issues/1"
