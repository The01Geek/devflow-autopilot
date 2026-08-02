#!/usr/bin/env bash
# Fixture slice (issue #1072): the only removal argument is the bare staging directory.
# It must yield an empty set (never an empty-suffix member matching every line) and refuse.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage"
}
