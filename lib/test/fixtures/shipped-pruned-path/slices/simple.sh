#!/usr/bin/env bash
# Fixture slice (issue #1072): derives exactly one prune target, lib/test.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  rm -rf "$stage/lib/test"
}
