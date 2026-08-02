#!/usr/bin/env bash
# Fixture slice (issue #1072): the staging variable is renamed to `work`. The lint must
# still derive the same target by identifying the staging variable from the function.
devflow_copy_slice() {
  local src="$1" dest="$2" work
  work="${dest}.vendor-stage.$$"
  rm -rf "$work"
  rm -rf "$work/lib/test"
}
