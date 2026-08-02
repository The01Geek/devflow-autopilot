#!/usr/bin/env bash
# Fixture slice (issue #1072): no local variable is assigned `$2`, so the destination
# parameter cannot be identified and the staging variable therefore cannot be either.
# The lint must refuse rather than guess a staging name.
devflow_copy_slice() {
  local src="$1" stage
  stage="/tmp/vendor-stage.$$"
  rm -rf "$stage/lib/test"
}
