#!/usr/bin/env bash
# Fixture slice (issue #1072): a qualifying target wrapped across a line continuation.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf \
    "$stage/lib/test"
}
