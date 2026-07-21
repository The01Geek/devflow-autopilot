#!/usr/bin/env bash
# Single quotes stop the shell expanding the variable, but the path is still not
# the placeholder form, so this is FLAGGED.
gh api 'repos/$GITHUB_REPOSITORY/issues/1'
