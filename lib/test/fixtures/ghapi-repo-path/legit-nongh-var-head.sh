#!/usr/bin/env bash
# A variable head whose name does NOT end in GH is outside the recognized set,
# so this is a declared residual and must stay unflagged.
"$MYTOOL" api "repos/$GITHUB_REPOSITORY/labels"
