#!/usr/bin/env bash
# Fixture slice (issue #1072): carries no devflow_copy_slice() at all, so the body
# cannot be established. The lint must refuse rather than audit against an empty set.
devflow_copy_other() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage/lib/test"
}
