#!/usr/bin/env bash
# The documented endpoint spelling carries a leading slash; interpolating the
# variable into it must not evade the guard.
gh api "/repos/$GITHUB_REPOSITORY/labels"
