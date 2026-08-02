#!/usr/bin/env bash
# Fixture slice (issue #1072): the qualifying removal sits OUTSIDE the function body. The
# lint scans only the function body, so it yields an empty set and refuses.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  mkdir -p "$stage"
}
rm -rf "$stage/lib/test"
