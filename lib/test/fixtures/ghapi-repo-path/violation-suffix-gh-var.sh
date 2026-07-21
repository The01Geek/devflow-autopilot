#!/usr/bin/env bash
# The head-set test is a NAME-SUFFIX test, not a DEVFLOW_GH equality test: any
# variable whose name ends in GH is a recognized head. Pins the positive half of
# that stated boundary, whose negative half legit-nongh-var-head.sh pins.
"$MY_GH" api "repos/$GITHUB_REPOSITORY/issues/1"
