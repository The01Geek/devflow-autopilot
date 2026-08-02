#!/usr/bin/env bash
# Fixture slice (issue #1072): devflow_copy_slice() is never closed by a bare `}` at
# column 0, so its body has no established end. The lint must refuse rather than treat
# the rest of the file as the body.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage/lib/test"
