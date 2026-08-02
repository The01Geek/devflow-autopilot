#!/usr/bin/env bash
# Fixture slice (issue #1072): the qualifying removal sits inside a conditional inside the
# function body — a future guarded prune must not be silently missed.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  if [ -d "$stage" ]; then
    rm -rf "$stage/lib/test"
  fi
}
